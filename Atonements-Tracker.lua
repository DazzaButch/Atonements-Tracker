local addonName, ns = ...
local DEFAULT_ATONEMENT_ID = 194384

-- 1. Database Initialization
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
}

--------------------------------------------------
-- 2. Main Tracker Icon
--------------------------------------------------
local frame = CreateFrame("Frame", "AtonementTrackerFrame", UIParent)
frame:SetPoint("CENTER", 0, 0)
frame:SetMovable(true)
frame:Hide()

local icon = frame:CreateTexture(nil, "BACKGROUND")
icon:SetAllPoints()

-- Dark Overlay Texture
local overlay = frame:CreateTexture(nil, "ARTWORK")
-- INSET: This pulls the corners in by 2 pixels so they don't stick out
overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
overlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
overlay:SetColorTexture(0, 0, 0) 

local timerText = frame:CreateFontString(nil, "OVERLAY")
local countText = frame:CreateFontString(nil, "OVERLAY")

local function RefreshUI()
    frame:SetSize(AtonementTrackerDB.size, AtonementTrackerDB.size)
    frame:SetAlpha(AtonementTrackerDB.alpha)
    
    icon:SetTexture(C_Spell.GetSpellTexture(AtonementTrackerDB.iconID or DEFAULT_ATONEMENT_ID))
    overlay:SetAlpha(AtonementTrackerDB.blackout or 0)
    
    timerText:SetFont(STANDARD_TEXT_FONT, AtonementTrackerDB.fontSize, "MONOCHROME, OUTLINE, THICKOUTLINE")
    countText:SetFont(STANDARD_TEXT_FONT, AtonementTrackerDB.countFontSize, "MONOCHROME, OUTLINE, THICKOUTLINE")
    
    timerText:SetShadowColor(0, 0, 0, 1)
    timerText:SetShadowOffset(1, -1)
    countText:SetShadowColor(0, 0, 0, 1)
    countText:SetShadowOffset(1, -1)
    
    timerText:ClearAllPoints()
    countText:ClearAllPoints()

if AtonementTrackerDB.swapPositions then
        -- Count: Nudge 2px Left, 2px Down
        countText:SetJustifyH("CENTER")
        countText:SetPoint("CENTER", frame, "CENTER", -2, -2)
        timerText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    else
        -- Timer: Nudge 2px Left, 2px Down
        timerText:SetJustifyH("CENTER")
        timerText:SetPoint("CENTER", frame, "CENTER", -2, -2)
        countText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    end
    
    frame:EnableMouse(not AtonementTrackerDB.locked)
    if not AtonementTrackerDB.locked then frame:RegisterForDrag("LeftButton") end
end

frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

--------------------------------------------------
-- 3. Core Logic
--------------------------------------------------
local shortestExpiration, atonementCount = 0, 0

local function ScanAtonements()
    shortestExpiration, atonementCount = 0, 0
    local units = {"player", "target", "focus"}
    if IsInRaid() then
        for i=1, GetNumGroupMembers() do table.insert(units, "raid"..i) end
    elseif IsInGroup() then
        for i=1, GetNumSubgroupMembers() do table.insert(units, "party"..i) end
    end

    local checkedGUIDs = {}
    for _, unit in ipairs(units) do
        if UnitExists(unit) and UnitIsFriend("player", unit) then
            local guid = UnitGUID(unit)
            if not checkedGUIDs[guid] then
                checkedGUIDs[guid] = true
                for i = 1, 40 do
                    local data = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
                    if not data then break end
                    if data.spellId == DEFAULT_ATONEMENT_ID and data.sourceUnit == "player" then
                        atonementCount = atonementCount + 1
                        if shortestExpiration == 0 or data.expirationTime < shortestExpiration then
                            shortestExpiration = data.expirationTime
                        end
                        break 
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
    else
        ScanAtonements()
    end
end)

frame:SetScript("OnUpdate", function()
    if atonementCount == 0 then return end
    local remaining = shortestExpiration - GetTime()
    if remaining > 0 then
        timerText:SetText(string.format("%.0f", remaining))
        countText:SetText(" x" .. atonementCount)
        timerText:SetTextColor(remaining <= 3 and 1 or 1, remaining <= 3 and 0.3 or 1, remaining <= 3 and 0.3 or 1)
    else
        timerText:SetText("")
        ScanAtonements()
    end
end)

--------------------------------------------------
-- 4. Options Window
--------------------------------------------------
local options = CreateFrame("Frame", "AtonementOptionsWindow", UIParent, "BackdropTemplate")
options:SetSize(250, 520) 
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
title:SetText("Atonement Tracker")

local close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

local function CreateSlider(name, label, min, max, y, dbKey)
    local s = CreateFrame("Slider", "AtTracker"..name, options, "OptionsSliderTemplate")
    s:SetPoint("TOP", 0, y)
    s:SetMinMaxValues(min, max)
    local step = (dbKey == "alpha" or dbKey == "scanInterval" or dbKey == "blackout") and 0.1 or 1
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetWidth(180)
    s:SetScript("OnShow", function(self) self:SetValue(AtonementTrackerDB[dbKey] or min) end)
    s:SetScript("OnValueChanged", function(self, value)
        AtonementTrackerDB[dbKey] = value
        RefreshUI()
        _G[self:GetName().."Text"]:SetText(label .. ": " .. (step < 1 and string.format("%.1f", value) or math.floor(value)))
    end)
    return s
end

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

-- Sliders
CreateSlider("SizeSl", "Icon Size", 20, 100, -120, "size")
CreateSlider("TimerFontSl", "Timer Font Size", 10, 50, -170, "fontSize")
CreateSlider("CountFontSl", "X Amount Font Size", 10, 50, -220, "countFontSize")
CreateSlider("AlphaSl", "Opacity", 0.1, 1.0, -270, "alpha")
CreateSlider("DarkSl", "Dark Overlay", 0.0, 1.0, -320, "blackout")

-- Icon ID EditBox
local iconLabel = options:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
iconLabel:SetPoint("TOPLEFT", 35, -370)
iconLabel:SetText("Custom Icon (Spell ID):")

local eb = CreateFrame("EditBox", "AtTrackerIconEB", options, "InputBoxTemplate")
eb:SetSize(180, 30)
eb:SetPoint("TOP", 5, -380)
eb:SetAutoFocus(false)
eb:SetNumeric(true)
eb:SetScript("OnShow", function(self) self:SetText(AtonementTrackerDB.iconID or 194384) end)
eb:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText())
    if val then 
        AtonementTrackerDB.iconID = val 
        RefreshUI() 
    end
    self:ClearFocus()
end)

-- Performance Slider
local perfSl = CreateSlider("PerfSl", "Update Rate", 0.1, 1.0, -450, "scanInterval")
local perfDesc = options:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
perfDesc:SetPoint("TOP", perfSl, "BOTTOM", 0, -17)
perfDesc:SetText("Seconds between scans. Default: 0.2\nLower is faster, higher is better CPU.")

SLASH_ATONEMENT1 = "/at"
SlashCmdList["ATONEMENT"] = function()
    if options:IsShown() then options:Hide() else options:Show() end
end
