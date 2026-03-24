local addonName, ns = ...
local DEFAULT_ATONEMENT_ID = 194384

-- 1. Database Initialization & Safety Check
local defaults = {
    size = 80,
    locked = false,
    alpha = 1.0,
    blackout = 0.6,
    fontSize = 22,
    countFontSize = 28,
    timerColor = {1, 1, 1},
    countColor = {1, 1, 1},
    timerX = 0, timerY = 0,
    countX = 0, countY = 0,
    hideIcon = false,
    scanInterval = 0.2,
    swapPositions = false,
    iconID = DEFAULT_ATONEMENT_ID,
    testMode = false,
}

AtonementTrackerDB = AtonementTrackerDB or {}
for k, v in pairs(defaults) do
    if AtonementTrackerDB[k] == nil then AtonementTrackerDB[k] = v end
end

--------------------------------------------------
-- 2. Main Tracker Icon & UI
--------------------------------------------------
local frame = CreateFrame("Frame", "AtonementTrackerFrame", UIParent)
frame:SetPoint("CENTER", 0, 0)
frame:SetMovable(true)
frame:Hide()

local icon = frame:CreateTexture(nil, "BACKGROUND")
icon:SetAllPoints()

local overlay = frame:CreateTexture(nil, "ARTWORK")
overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
overlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
overlay:SetColorTexture(0, 0, 0) 

local timerText = frame:CreateFontString(nil, "OVERLAY")
local countText = frame:CreateFontString(nil, "OVERLAY")

local function RefreshUI()
    local tCol = AtonementTrackerDB.timerColor or {1, 1, 1}
    local cCol = AtonementTrackerDB.countColor or {1, 1, 1}

    frame:SetSize(AtonementTrackerDB.size, AtonementTrackerDB.size)
    frame:SetAlpha(AtonementTrackerDB.alpha)
    
    if AtonementTrackerDB.hideIcon then
        icon:SetAlpha(0)
        overlay:SetAlpha(0)
    else
        icon:SetAlpha(1)
        icon:SetTexture(C_Spell.GetSpellTexture(AtonementTrackerDB.iconID or DEFAULT_ATONEMENT_ID))
        overlay:SetAlpha(AtonementTrackerDB.blackout or 0)
    end
    
    local fontFlags = "MONOCHROME, OUTLINE, THICKOUTLINE"
    timerText:SetFont(STANDARD_TEXT_FONT, AtonementTrackerDB.fontSize, fontFlags)
    countText:SetFont(STANDARD_TEXT_FONT, AtonementTrackerDB.countFontSize, fontFlags)
    
    timerText:SetTextColor(unpack(tCol))
    countText:SetTextColor(unpack(cCol))
    
    timerText:ClearAllPoints()
    countText:ClearAllPoints()

    if AtonementTrackerDB.swapPositions then
        countText:SetPoint("CENTER", frame, "CENTER", AtonementTrackerDB.countX, AtonementTrackerDB.countY)
        timerText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", AtonementTrackerDB.timerX - 2, AtonementTrackerDB.timerY + 2)
    else
        timerText:SetPoint("CENTER", frame, "CENTER", AtonementTrackerDB.timerX, AtonementTrackerDB.timerY)
        countText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", AtonementTrackerDB.countX - 2, AtonementTrackerDB.countY + 2)
    end
    
    frame:EnableMouse(not AtonementTrackerDB.locked)
    if not AtonementTrackerDB.locked then frame:RegisterForDrag("LeftButton") end

    if AtonementTrackerDB.testMode then
        frame:Show()
        timerText:SetText("8")
        countText:SetText("x5")
    end
end

frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

--------------------------------------------------
-- 3. Core Logic (Fixed for Taint/Secret Numbers)
--------------------------------------------------
local shortestExpiration, atonementCount = 0, 0
local cachedUnits = {"player", "target", "focus"}
local lastScan = 0

local function UpdateUnitCache()
    wipe(cachedUnits)
    table.insert(cachedUnits, "player")
    table.insert(cachedUnits, "target")
    table.insert(cachedUnits, "focus")
    
    if IsInRaid() then
        for i=1, GetNumGroupMembers() do 
            local unit = "raid"..i
            if not UnitIsUnit(unit, "player") then table.insert(cachedUnits, unit) end
        end
    elseif IsInGroup() then
        for i=1, GetNumSubgroupMembers() do 
            table.insert(cachedUnits, "party"..i)
        end
    end
end

local function ScanAtonements()
    if AtonementTrackerDB.testMode then return end
    
    shortestExpiration, atonementCount = 0, 0
    local checkedGUIDs = {}
    local spellName = C_Spell.GetSpellName(DEFAULT_ATONEMENT_ID)

    if not spellName then return end

    for i = 1, #cachedUnits do
        local unit = cachedUnits[i]
        if UnitExists(unit) and UnitIsFriend("player", unit) then
            local guid = UnitGUID(unit)
            if guid and not checkedGUIDs[guid] then
                checkedGUIDs[guid] = true
                
                -- Safe search using pcall to catch Blizzard UI taint errors silently
                local success, data = pcall(function() 
                    return C_UnitAuras.GetAuraDataBySpellName(unit, spellName, "HELPFUL") 
                end)

                if success and data and data.sourceUnit == "player" then
                    atonementCount = atonementCount + 1
                    if shortestExpiration == 0 or data.expirationTime < shortestExpiration then
                        shortestExpiration = data.expirationTime
                    end
                end
            end
        end
    end
    
    if atonementCount > 0 then frame:Show() else frame:Hide() end
end

frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        RefreshUI()
        UpdateUnitCache()
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        UpdateUnitCache()
        ScanAtonements()
    else
        ScanAtonements()
    end
end)

frame:SetScript("OnUpdate", function(self, elapsed)
    if AtonementTrackerDB.testMode then return end
    
    lastScan = lastScan + elapsed
    if lastScan >= (AtonementTrackerDB.scanInterval or 0.2) then
        ScanAtonements()
        lastScan = 0
    end

    if atonementCount > 0 then
        local remaining = shortestExpiration - GetTime()
        if remaining > 0 then
            timerText:SetText(string.format("%.0f", remaining))
            countText:SetText("x" .. atonementCount)
            -- Apply user color setting without hardcoded red overrides
            timerText:SetTextColor(unpack(AtonementTrackerDB.timerColor or {1,1,1}))
        else
            timerText:SetText("")
            frame:Hide()
        end
    end
end)

--------------------------------------------------
-- 4. Options Window
--------------------------------------------------
local options = CreateFrame("Frame", "AtonementOptionsWindow", UIParent, "BackdropTemplate")
options:SetSize(260, 720) 
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

local title = options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -12)
title:SetText("Atonement Tracker Settings")

local close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

local function CreateSlider(name, label, min, max, y, dbKey, tooltip)
    local s = CreateFrame("Slider", "AtTracker"..name, options, "OptionsSliderTemplate")
    s:SetPoint("TOP", 0, y)
    s:SetMinMaxValues(min, max)
    local step = (dbKey:find("alpha") or dbKey:find("scan") or dbKey:find("blackout")) and 0.1 or 1
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetWidth(180)
    s:SetScript("OnShow", function(self) self:SetValue(AtonementTrackerDB[dbKey] or 0) end)
    s:SetScript("OnValueChanged", function(self, value)
        AtonementTrackerDB[dbKey] = value
        RefreshUI()
        _G[self:GetName().."Text"]:SetText(label .. ": " .. (step < 1 and string.format("%.1f", value) or math.floor(value)))
    end)
    s:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 1, 1)
        GameTooltip:AddLine(tooltip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return s
end

local function CreateCB(name, label, y, dbKey, tooltip)
    local cb = CreateFrame("CheckButton", "AtTracker"..name.."CB", options, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 30, y)
    _G[cb:GetName().."Text"]:SetText(label)
    cb:SetScript("OnShow", function(self) self:SetChecked(AtonementTrackerDB[dbKey]) end)
    cb:SetScript("OnClick", function(self) AtonementTrackerDB[dbKey] = self:GetChecked() RefreshUI() end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 1, 1)
        GameTooltip:AddLine(tooltip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return cb
end

CreateCB("Test", "Test Mode", -40, "testMode", "Shows the frame with dummy data for easy adjustment.")
CreateCB("Lock", "Lock Frame", -65, "locked", "Prevents dragging and enables click-through.")
CreateCB("Swap", "Swap Positions", -90, "swapPositions", "Switches the placement of the timer and the count.")
CreateCB("Hide", "Hide Icon (Text Only)", -115, "hideIcon", "Hides the spell icon and dark background.")

CreateSlider("SizeSl", "Icon Size", 20, 140, -170, "size", "Overall scale of the tracker frame.")
CreateSlider("AlphaSl", "Opacity", 0.1, 1.0, -210, "alpha", "Sets the transparency of the entire addon.")
CreateSlider("DarkSl", "Overlay Dark", 0.0, 1.0, -250, "blackout", "Adjusts the darkness of the icon overlay.")

CreateSlider("TFontSl", "Timer - Font Size", 10, 50, -300, "fontSize", "Size of the countdown number.")
CreateSlider("TXSl", "Timer - X Offset", -100, 100, -340, "timerX", "Nudge the timer left or right.")
CreateSlider("TYSl", "Timer - Y Offset", -100, 100, -380, "timerY", "Nudge the timer up or down.")

CreateSlider("CFontSl", "X Count - Font Size", 10, 50, -430, "countFontSize", "Size of the 'xAmount' text.")
CreateSlider("CXSl", "X Count - X Offset", -100, 100, -470, "countX", "Nudge the count left or right.")
CreateSlider("CYSl", "X Count - Y Offset", -100, 100, -510, "countY", "Nudge the count up or down.")

local function OpenColorPicker(dbKey)
    local r, g, b = unpack(AtonementTrackerDB[dbKey] or {1,1,1})
    ColorPickerFrame:SetupColorPickerAndShow({
        swatchFunc = function()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            AtonementTrackerDB[dbKey] = {nr, ng, nb}
            RefreshUI()
        end,
        r = r, g = g, b = b,
        hasAlpha = false,
    })
end

local tColBtn = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
tColBtn:SetSize(100, 22)
tColBtn:SetPoint("TOPLEFT", 30, -550)
tColBtn:SetText("Timer Color")
tColBtn:SetScript("OnClick", function() OpenColorPicker("timerColor") end)

local cColBtn = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
cColBtn:SetSize(100, 22)
cColBtn:SetPoint("TOPRIGHT", -30, -550)
cColBtn:SetText("X Count Color")
cColBtn:SetScript("OnClick", function() OpenColorPicker("countColor") end)

local ebLabel = options:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
ebLabel:SetPoint("TOPLEFT", 35, -590)
ebLabel:SetText("Custom Icon (Spell ID):")

local eb = CreateFrame("EditBox", "AtTrackerIconEB", options, "InputBoxTemplate")
eb:SetSize(180, 30)
eb:SetPoint("TOP", 5, -605)
eb:SetAutoFocus(false)
eb:SetNumeric(true)
eb:SetScript("OnShow", function(self) self:SetText(AtonementTrackerDB.iconID or 194384) end)
eb:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText())
    if val then AtonementTrackerDB.iconID = val RefreshUI() end
    self:ClearFocus()
end)

CreateSlider("PerfSl", "Update Rate", 0.1, 1.0, -665, "scanInterval", "How often to scan for auras. Lower is more responsive but uses more CPU.")

SLASH_ATONEMENT1 = "/at"
SlashCmdList["ATONEMENT"] = function()
    if options:IsShown() then options:Hide() else options:Show() end
end
