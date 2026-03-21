-- Atonement Tracker (Retail 12.0.1) — Combat-log assisted detection
-- Replace your addon file with this version, /reload, then cast Atonement and test.
-- This build:
--  - Uses C_UnitAuras when available
--  - Falls back safely if UnitAura is present (some clients don't expose it)
--  - Listens to COMBAT_LOG_EVENT_UNFILTERED to detect SPELL_AURA_APPLIED/REFRESH for the atonement spellId(s)
--  - Triggers a quick rescan after combat-log detection so the icon reliably reappears
--  - Keeps options and debug prints minimal

local addonName, ns = ...
local DEFAULT_ATONEMENT_ID = 194384
local ATONEMENT_NAME = "Atonement"

-- SavedVariables defaults
AtonementTrackerDB = AtonementTrackerDB or {
    size = 80,
    locked = false,
    alpha = 1.0,
    blackout = 0.6,
    fontSize = 22,
    countFontSize = 28,
    scanInterval = 0.2,
    swapPositions = false,
    iconID = DEFAULT_ATONEMENT_ID,
    yOffset = 0,
    xOffset = 0,
}

--------------------------------------------------
-- Helpers
--------------------------------------------------
local function SafePrint(...)
    if print then print("|cffffff00AtonementTracker:|r", ...) end
end

local function GetSpellTextureSafe(spellId)
    if not spellId then return nil end
    local ok, tex = pcall(C_Spell.GetSpellTexture, spellId)
    if ok and tex then return tex end
    local _, _, icon = GetSpellInfo(spellId)
    if icon then return icon end
    return nil
end

local function BuildUnitList()
    local units = {"player", "target", "focus"}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units+1] = "raid"..i end
    elseif IsInGroup() then
        local gs = GetNumGroupMembers()
        for i = 1, math.max(0, gs - 1) do units[#units+1] = "party"..i end
    end
    return units
end

--------------------------------------------------
-- Aura detection (C_UnitAuras preferred)
--------------------------------------------------
local function GetAtonementAura_CUnitAuras(unit)
    if C_UnitAuras and type(C_UnitAuras.GetAuraDataBySpellName) == "function" then
        local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, ATONEMENT_NAME, "HELPFUL|PLAYER")
        if ok and data and data.expirationTime and data.expirationTime > 0 then
            return { expirationTime = data.expirationTime, spellId = data.spellId, name = data.name }
        end
    end
    return nil
end

local function GetAtonementAura_FallbackUnitAura(unit)
    if type(UnitAura) ~= "function" then return nil end
    local targetSpellId = (AtonementTrackerDB and AtonementTrackerDB.iconID) or DEFAULT_ATONEMENT_ID
    for i = 1, 40 do
        local name, _, _, _, _, expirationTime, _, _, _, spellId = UnitAura(unit, i, "HELPFUL|PLAYER")
        if not name then break end
        if spellId and (spellId == targetSpellId or spellId == DEFAULT_ATONEMENT_ID) then
            return { expirationTime = expirationTime, spellId = spellId, name = name }
        end
        if name == ATONEMENT_NAME then
            return { expirationTime = expirationTime, spellId = spellId, name = name }
        end
    end
    return nil
end

local function GetAtonementAura(unit)
    -- Try C_UnitAuras first (Retail)
    local data = GetAtonementAura_CUnitAuras(unit)
    if data then return data end
    -- Fallback to UnitAura if available
    return GetAtonementAura_FallbackUnitAura(unit)
end

--------------------------------------------------
-- UI
--------------------------------------------------
local frame = CreateFrame("Frame", "AtonementTrackerFrame", UIParent)
frame:SetPoint("CENTER", 0, 0)
frame:SetMovable(true)
frame:Hide()
frame:SetClampedToScreen(true)

local icon = frame:CreateTexture(nil, "BACKGROUND")
icon:SetAllPoints()

local overlay = frame:CreateTexture(nil, "ARTWORK")
overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
overlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
overlay:SetColorTexture(0, 0, 0)

local timerText = frame:CreateFontString(nil, "OVERLAY")
local countText = frame:CreateFontString(nil, "OVERLAY")

frame:EnableMouse(true)
frame:SetScript("OnEnter", function(self)
    if atonementCount and atonementCount > 0 then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Atonement Tracker", 1, 1, 1)
        GameTooltip:AddLine(("Players with %s: %d"):format(ATONEMENT_NAME, atonementCount), 1, 0.85, 0)
        if shortestExpiration and shortestExpiration > 0 then
            local remaining = shortestExpiration - GetTime()
            if remaining > 0 then
                GameTooltip:AddLine(("Shortest remaining: %.1f s"):format(remaining), 0.8, 0.8, 0.8)
            end
        end
        GameTooltip:AddLine("Right-click to toggle lock; Middle-click to reset", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end
end)
frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

frame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
        AtonementTrackerDB.locked = not AtonementTrackerDB.locked
        RefreshUI()
    elseif button == "MiddleButton" then
        self:ClearAllPoints()
        self:SetPoint("CENTER", 0, 0)
    end
end)

frame:SetScript("OnDragStart", function(self) if not AtonementTrackerDB.locked then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

--------------------------------------------------
-- State and scanning
--------------------------------------------------
local shortestExpiration, atonementCount = 0, 0
local dirty = true
local lastScanTime = 0
local apisReady = false
local isInitialized = false

local function RefreshUI()
    if not AtonementTrackerDB then return end

    frame:SetSize(AtonementTrackerDB.size or 80, AtonementTrackerDB.size or 80)
    frame:SetAlpha(AtonementTrackerDB.alpha or 1.0)

    local spellIdToUse = AtonementTrackerDB.iconID or DEFAULT_ATONEMENT_ID
    local tex = GetSpellTextureSafe(spellIdToUse) or GetSpellTextureSafe(DEFAULT_ATONEMENT_ID)
    if tex then
        icon:SetTexture(tex)
    else
        icon:SetTexture(nil)
        SafePrint("failed to get texture for spellId", spellIdToUse)
    end

    overlay:SetAlpha(AtonementTrackerDB.blackout or 0)

    timerText:SetFont(STANDARD_TEXT_FONT, AtonementTrackerDB.fontSize or 22, "OUTLINE")
    countText:SetFont(STANDARD_TEXT_FONT, AtonementTrackerDB.countFontSize or 28, "OUTLINE")

    timerText:SetJustifyH("CENTER")
    countText:SetJustifyH("CENTER")

    timerText:ClearAllPoints()
    countText:ClearAllPoints()

    if AtonementTrackerDB.swapPositions then
        countText:SetPoint("CENTER", frame, "CENTER", AtonementTrackerDB.xOffset or 0, AtonementTrackerDB.yOffset or 0)
        timerText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    else
        timerText:SetPoint("CENTER", frame, "CENTER", AtonementTrackerDB.xOffset or 0, AtonementTrackerDB.yOffset or 0)
        countText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    end

    if AtonementTrackerDB.locked then
        frame:EnableMouse(false)
        frame:SetMovable(false)
    else
        frame:EnableMouse(true)
        frame:SetMovable(true)
        frame:RegisterForDrag("LeftButton")
    end

    isInitialized = true
end

local function ScanAtonements()
    if not isInitialized or not apisReady then return end

    shortestExpiration, atonementCount = 0, 0
    local units = BuildUnitList()
    local seen = {}
    local foundSpellIdForTexture = nil

    for _, unit in ipairs(units) do
        if UnitExists(unit) and UnitIsFriend("player", unit) then
            local guid = UnitGUID(unit)
            if guid and not seen[guid] then
                seen[guid] = true
                local data = GetAtonementAura(unit)
                if data and data.expirationTime and data.expirationTime > 0 then
                    atonementCount = atonementCount + 1
                    if data.spellId and not foundSpellIdForTexture then foundSpellIdForTexture = data.spellId end
                    if shortestExpiration == 0 or data.expirationTime < shortestExpiration then
                        shortestExpiration = data.expirationTime
                    end
                end
            end
        end
    end

    if foundSpellIdForTexture then
        local tex = GetSpellTextureSafe(foundSpellIdForTexture)
        if tex then
            icon:SetTexture(tex)
            AtonementTrackerDB.iconID = foundSpellIdForTexture
        end
    end

    if atonementCount > 0 then
        frame:Show()
    else
        frame:Hide()
    end

    dirty = false
    lastScanTime = GetTime()
end

--------------------------------------------------
-- Combat log listener to catch aura application
--------------------------------------------------
local function OnCombatLogEvent()
    -- parse combat log
    local timestamp, subevent, hideCaster,
          sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags,
          spellId, spellName = CombatLogGetCurrentEventInfo()

    -- subevents of interest: SPELL_AURA_APPLIED, SPELL_AURA_REFRESH
    if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REFRESH" then
        -- check against configured iconID, default, and a common alternate (user reported 331475)
        local watched = {}
        watched[ AtonementTrackerDB.iconID or DEFAULT_ATONEMENT_ID ] = true
        watched[ DEFAULT_ATONEMENT_ID ] = true
        watched[331475] = true -- include the ID you reported earlier as a fallback

        if spellId and watched[spellId] then
            -- quick rescan shortly after the combat log event to let aura data populate
            if C_Timer then
                C_Timer.After(0.05, function()
                    apisReady = true
                    dirty = true
                    ScanAtonements()
                end)
            else
                apisReady = true
                dirty = true
                ScanAtonements()
            end
        end
    end
end

--------------------------------------------------
-- Event handling
--------------------------------------------------
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == addonName then
        local defaults = {
            size = 80,
            locked = false,
            alpha = 1.0,
            blackout = 0.6,
            fontSize = 22,
            countFontSize = 28,
            scanInterval = 0.2,
            swapPositions = false,
            iconID = DEFAULT_ATONEMENT_ID,
            yOffset = 0,
            xOffset = 0,
        }
        for k, v in pairs(defaults) do
            if AtonementTrackerDB[k] == nil then AtonementTrackerDB[k] = v end
        end
        RefreshUI()
        dirty = true
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        apisReady = true
        dirty = true
        ScanAtonements()
    elseif event == "UNIT_AURA" then
        local unit = arg1
        if unit and (unit == "player" or unit == "target" or unit == "focus" or string.match(unit, "^party") or string.match(unit, "^raid")) then
            dirty = true
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit = arg1
        if unit and (unit == "player" or unit == "target" or unit == "focus" or string.match(unit, "^party") or string.match(unit, "^raid")) then
            -- short delay to allow aura application
            if C_Timer then C_Timer.After(0.05, function() dirty = true; ScanAtonements() end) end
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLogEvent()
    else
        dirty = true
    end
end)

frame:SetScript("OnUpdate", function(self, elapsed)
    if not isInitialized then isInitialized = true end
    if not apisReady then return end

    local interval = AtonementTrackerDB.scanInterval or 0.2
    if dirty and (GetTime() - lastScanTime >= interval) then
        ScanAtonements()
    end

    if atonementCount and atonementCount > 0 then
        local remaining = shortestExpiration - GetTime()
        if remaining > 0 then
            timerText:SetText(string.format("%.0f", remaining))
            countText:SetText("x" .. atonementCount)
            local r, g, b = 1, 1, 1
            if remaining > 6 then r, g, b = 0.2, 1, 0.2
            elseif remaining > 3 then r, g, b = 1, 1, 0.2
            else r, g, b = 1, 0.4, 0.4 end
            timerText:SetTextColor(r, g, b)
            countText:SetTextColor(1, 1, 1)
        else
            timerText:SetText("")
            countText:SetText("x" .. atonementCount)
            timerText:SetTextColor(1, 1, 1)
        end
    else
        timerText:SetText("")
        countText:SetText("")
    end
end)

--------------------------------------------------
-- Options window and slash (kept minimal)
--------------------------------------------------
local options = CreateFrame("Frame", "AtonementOptionsWindow", UIParent, "BackdropTemplate")
options:SetSize(250, 620)
options:SetPoint("CENTER")
options:SetFrameStrata("DIALOG")
options:SetMovable(true)
options:EnableMouse(true)
options:RegisterForDrag("LeftButton")
options:SetScript("OnDragStart", options.StartMoving)
options:SetScript("OnDragStop", options.StopMovingOrSizing)
options:Hide()

options:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
options:SetBackdropColor(0, 0, 0, 0.9)

local function CreateSlider(name, label, min, max, y, dbKey, step)
    local s = CreateFrame("Slider", "AtTracker"..name, options, "OptionsSliderTemplate")
    s:SetPoint("TOP", 0, y)
    s:SetMinMaxValues(min, max)
    step = step or ((dbKey == "alpha" or dbKey == "scanInterval" or dbKey == "blackout") and 0.1 or 1)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetWidth(180)
    s:SetScript("OnShow", function(self)
        local v = AtonementTrackerDB[dbKey]
        if v == nil then v = min end
        self:SetValue(v)
        local display = (step < 1) and string.format("%.1f", v) or tostring(math.floor(v))
        _G[self:GetName().."Text"]:SetText(label .. ": " .. display)
    end)
    s:SetScript("OnValueChanged", function(self, value)
        if step < 1 then value = tonumber(string.format("%.1f", value)) else value = math.floor(value + 0.5) end
        AtonementTrackerDB[dbKey] = value
        RefreshUI()
        _G[self:GetName().."Text"]:SetText(label .. ": " .. ((step < 1) and string.format("%.1f", value) or tostring(value)))
    end)
    return s
end

local title = options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -12)
title:SetText("Atonement Tracker")

local close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

local lockCb = CreateFrame("CheckButton", "AtTrackerLockCB", options, "InterfaceOptionsCheckButtonTemplate")
lockCb:SetPoint("TOPLEFT", 30, -40)
_G[lockCb:GetName().."Text"]:SetText("Lock (Click-Through)")
lockCb:SetScript("OnShow", function(self) self:SetChecked(AtonementTrackerDB.locked) end)
lockCb:SetScript("OnClick", function(self) AtonementTrackerDB.locked = self:GetChecked() RefreshUI() end)

local swapCb = CreateFrame("CheckButton", "AtTrackerSwapCB", options, "InterfaceOptionsCheckButtonTemplate")
swapCb:SetPoint("TOPLEFT", 30, -65)
_G[swapCb:GetName().."Text"]:SetText("Swap Timer/Count")
swapCb:SetScript("OnShow", function(self) self:SetChecked(AtonementTrackerDB.swapPositions) end)
swapCb:SetScript("OnClick", function(self) AtonementTrackerDB.swapPositions = self:GetChecked() RefreshUI() end)

CreateSlider("SizeSl", "Icon Size", 20, 200, -110, "size", 1)
CreateSlider("AlphaSl", "Opacity", 0.1, 1.0, -155, "alpha", 0.1)
CreateSlider("DarkSl", "Dark Overlay", 0.0, 1.0, -200, "blackout", 0.1)
CreateSlider("TimerFontSl", "Timer Font Size", 10, 80, -245, "fontSize", 1)
CreateSlider("CountFontSl", "X Amount Font Size", 10, 80, -290, "countFontSize", 1)
CreateSlider("VertSl", "Center Text Y Offset", -50, 50, -335, "yOffset", 1)
CreateSlider("HorizSl", "Center Text X Offset", -50, 50, -380, "xOffset", 1)

local ebLabel = options:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ebLabel:SetPoint("TOPLEFT", 35, -435)
ebLabel:SetText("Custom Spell ID Code:")

local eb = CreateFrame("EditBox", "AtTrackerIconEB", options, "InputBoxTemplate")
eb:SetSize(180, 30)
eb:SetPoint("TOP", 5, -440)
eb:SetAutoFocus(false)
eb:SetNumeric(true)

eb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Custom Spell Icon", 1, 1, 1)
    GameTooltip:AddLine("Enter a Spell ID (e.g., 194384) to change the icon.", 1, 0.8, 0, true)
    GameTooltip:AddLine("Press Enter to save.", 0, 1, 0)
    GameTooltip:Show()
end)
eb:SetScript("OnLeave", function() GameTooltip:Hide() end)

eb:SetScript("OnShow", function(self) self:SetText(AtonementTrackerDB.iconID or DEFAULT_ATONEMENT_ID) end)
eb:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText())
    if val then
        AtonementTrackerDB.iconID = val
        RefreshUI()
    end
    self:ClearFocus()
end)

CreateSlider("PerfSl", "Update Rate", 0.1, 1.0, -510, "scanInterval", 0.1)

local reset = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
reset:SetSize(120, 25)
reset:SetPoint("BOTTOM", 0, 15)
reset:SetText("Reset Position")
reset:SetScript("OnClick", function()
    AtonementTrackerFrame:ClearAllPoints()
    AtonementTrackerFrame:SetPoint("CENTER", 0, 0)
end)

SLASH_ATONEMENT1 = "/at"
SlashCmdList["ATONEMENT"] = function(msg)
    if msg and msg:lower():match("^test") then
        SafePrint("Manual test scan triggered")
        apisReady = true
        dirty = true
        ScanAtonements()
        frame:Show()
        return
    end
    if options:IsShown() then options:Hide() else options:Show() end
end

-- initial refresh
if C_Timer then C_Timer.After(0.5, function() RefreshUI() end) else RefreshUI() end
