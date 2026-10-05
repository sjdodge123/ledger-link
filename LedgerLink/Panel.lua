-- The Ledger Link panel (/rl, or the minimap button): export buttons, ruleset,
-- the beta-only region picker, public guild notes, recorded pulls, beta probe.
-- Every control calls the same functions as the slash commands.
local _, ns = ...

local Panel = {}
ns.Panel = Panel

local RULESETS = {
    { value = "normal", label = "Normal" }, { value = "pvp", label = "PvP" },
    { value = "roleplaying", label = "RP" }, { value = "hardcore", label = "Hardcore" },
}
local REGIONS = { "us", "eu", "kr", "tw", "cn" }

local frame, title, pullsLabel, rulesetLabel, regionLabel, notesBox
local rulesetButtons, regionButtons = {}, {}

local function setShown(widget, shown)
    if shown then widget:Show() else widget:Hide() end
end

-- True when the game reports a real region (1-5), so no picker is needed.
local function clientRegionKnown()
    local region = ns.SafeCall(GetCurrentRegion)
    return type(region) == "number" and region >= 1 and region <= 5
end

local function create()
    local f = ns.UI.Window("LedgerLinkPanel", 320, 290)
    title = ns.UI.Label(f, nil, "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)

    local y = -48
    local exportLabel = ns.UI.Label(f, "Export to Raid Ledger")
    exportLabel:SetPoint("TOPLEFT", 24, y)
    y = y - 20
    local x = 24
    for _, e in ipairs({ { "char", "Character" }, { "guild", "Guild" }, { "raid", "Raid" } }) do
        local section = e[1]
        local b = ns.UI.Button(f, e[2], 88, function()
            ns.lastCommand = "panel: export " .. section
            ns.RunExport(section)
        end, "LedgerLinkPanelExport" .. section:gsub("^%l", string.upper))
        b:SetPoint("TOPLEFT", x, y)
        x = x + 92
    end

    y = y - 34
    rulesetLabel = ns.UI.Label(f)
    rulesetLabel:SetPoint("TOPLEFT", 24, y)
    y = y - 20
    x = 24
    for _, r in ipairs(RULESETS) do
        local value = r.value
        local b = ns.UI.Button(f, r.label, 66, function() ns.SetRuleset(value) end, "LedgerLinkPanelRuleset" .. value)
        b:SetPoint("TOPLEFT", x, y)
        rulesetButtons[value] = b
        x = x + 68
    end

    y = y - 30
    regionLabel = ns.UI.Label(f, "Region (the beta doesn't report it):")
    regionLabel:SetPoint("TOPLEFT", 24, y)
    x = 24
    for _, name in ipairs(REGIONS) do
        local b = ns.UI.Button(f, name:upper(), 50, function() ns.SetRegion(name) end, "LedgerLinkPanelRegion" .. name)
        b:SetPoint("TOPLEFT", x, y - 20)
        regionButtons[name] = b
        x = x + 54
    end

    y = y - 52
    notesBox = CreateFrame("CheckButton", "LedgerLinkPanelGuildNotes", f, "UICheckButtonTemplate")
    notesBox:SetPoint("TOPLEFT", 20, y)
    notesBox:SetScript("OnClick", function(self) ns.SetGuildNotes(self:GetChecked()) end)
    local notesLabel = ns.UI.Label(f, "Include public guild notes (officer notes never)", "GameFontHighlightSmall")
    notesLabel:SetPoint("LEFT", notesBox, "RIGHT", 2, 0)

    y = y - 34
    pullsLabel = ns.UI.Label(f, nil, "GameFontHighlight")
    pullsLabel:SetPoint("TOPLEFT", 24, y - 4)
    local clear = ns.UI.Button(f, "Clear", 60, function() ns.ClearPulls() end, "LedgerLinkPanelClearPulls")
    clear:SetPoint("TOPRIGHT", -24, y)

    local probe = ns.UI.Button(f, "Beta probe", 100, function()
        ns.lastCommand = "panel: probe"
        ns.Probe.Show()
    end, "LedgerLinkPanelProbe")
    probe:SetPoint("BOTTOMLEFT", 24, 18)
    local hint = ns.UI.Label(f, "/rl help for commands", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", -24, 24)

    frame = f
end

--- Re-read every setting into the controls (called on show and after changes).
function Panel.Refresh()
    if not frame then return end
    title:SetText("Ledger Link " .. ns.VERSION)
    local ruleset = LedgerLinkCharDB and LedgerLinkCharDB.ruleset
    rulesetLabel:SetText("Ruleset: " .. (ruleset or "not set"))
    for value, b in pairs(rulesetButtons) do
        if value == ruleset then b:LockHighlight() else b:UnlockHighlight() end
    end
    local needRegion = not clientRegionKnown()
    setShown(regionLabel, needRegion)
    for name, b in pairs(regionButtons) do
        setShown(b, needRegion)
        if name == LedgerLinkDB.region then b:LockHighlight() else b:UnlockHighlight() end
    end
    notesBox:SetChecked(LedgerLinkDB.guildNotes and true or false)
    pullsLabel:SetText(Panel.GetPullsText())
end

function Panel.GetPullsText()
    return string.format("Recorded boss pulls: %d", #ns.Raid.Pulls())
end

function Panel.Show()
    if not frame then create() end
    frame:Show()
    Panel.Refresh()
end

function Panel.Hide()
    if frame then frame:Hide() end
end

function Panel.IsShown()
    return frame ~= nil and frame:IsShown() and true or false
end

function Panel.Toggle()
    if Panel.IsShown() then Panel.Hide() else Panel.Show() end
end
