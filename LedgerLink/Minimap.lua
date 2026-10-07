-- Minimap button: click toggles the panel, drag moves it around the minimap
-- edge (angle saved in LedgerLinkDB.minimap), hover shows status.
-- /rl minimap off hides it. No library: a plain child of Minimap.
local _, ns = ...

local Minimap_ = {}
ns.Minimap = Minimap_

Minimap_.ICON = "Interface\\AddOns\\LedgerLink\\Textures\\Minimap"
Minimap_.DEFAULT_ANGLE = 225

local button

local function settings()
    LedgerLinkDB.minimap = type(LedgerLinkDB.minimap) == "table" and LedgerLinkDB.minimap or {}
    local s = LedgerLinkDB.minimap
    if type(s.angle) ~= "number" then s.angle = Minimap_.DEFAULT_ANGLE end
    return s
end

local function place()
    local angle = math.rad(settings().angle)
    local radius = (Minimap:GetWidth() or 140) / 2 + 10
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function followCursor()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    local angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    settings().angle = angle % 360
    place()
end

local function showTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Ledger Link " .. ns.VERSION)
    GameTooltip:AddLine("Click: open the panel. Drag: move this button.", 1, 1, 1)
    GameTooltip:AddLine("Ruleset: " .. ns.Identity.RulesetText(), 1, 1, 1)
    GameTooltip:AddLine(string.format("Recorded boss pulls: %d", #ns.Raid.Pulls()), 1, 1, 1)
    GameTooltip:Show()
end

local function create()
    button = CreateFrame("Button", "LedgerLinkMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("CENTER")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(Minimap_.ICON)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    button:SetScript("OnClick", function() ns.Panel.Toggle() end)
    button:SetScript("OnEnter", showTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", followCursor)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
end

--- Create (once) and show or hide per the saved setting. Called from ns.Init.
function Minimap_.Init()
    if type(Minimap) ~= "table" then return end
    if not button then create() end
    place()
    if settings().hide then button:Hide() else button:Show() end
end

function Minimap_.SetShown(shown)
    settings().hide = not shown
    Minimap_.Init()
end
