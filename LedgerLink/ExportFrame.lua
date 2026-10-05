-- Copyable export window (WeakAuras/Details pattern): a movable frame with
-- a read-only-feeling multi-line EditBox, pre-selected text and Escape to close.
local _, ns = ...

local ExportFrame = {}
ns.ExportFrame = ExportFrame

local frame, editBox, title, sizeLabel
local currentText = ""

local function selectAll()
    editBox:SetFocus()
    editBox:HighlightText()
end

local function createBackdrop(f)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end
end

local function createEditBox(parent)
    local scroll = CreateFrame("ScrollFrame", "LedgerLinkExportScroll", parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -48)
    scroll:SetPoint("BOTTOMRIGHT", -40, 48)
    local box = CreateFrame("EditBox", "LedgerLinkExportEditBox", scroll)
    box:SetMultiLine(true)
    box:SetMaxLetters(0)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(500)
    box:SetScript("OnEscapePressed", function() frame:Hide() end)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(currentText)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    scroll:SetScrollChild(box)
    return box
end

local function createButtons(parent)
    local select = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    select:SetSize(120, 22)
    select:SetPoint("BOTTOMLEFT", 20, 16)
    select:SetText("Select all")
    select:SetScript("OnClick", selectAll)
    local close = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
end

local function create()
    local ok, f = pcall(CreateFrame, "Frame", "LedgerLinkExportFrame", UIParent, "BackdropTemplate")
    if not ok then f = CreateFrame("Frame", "LedgerLinkExportFrame", UIParent) end
    f:SetSize(580, 380)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    createBackdrop(f)
    title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    sizeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sizeLabel:SetPoint("BOTTOMRIGHT", -24, 20)
    frame = f
    editBox = createEditBox(f)
    createButtons(f)
    -- Escape closes the window even when the edit box isn't focused.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "LedgerLinkExportFrame")
    end
end

--- Show `text` for `section`, pre-selected for Ctrl+C.
function ExportFrame.Show(section, text)
    if not frame then create() end
    currentText = text
    title:SetText("Ledger Link - " .. section .. " export")
    sizeLabel:SetText(string.format("%.1f KB - Ctrl+C, then paste into Raid Ledger -> Import string", #text / 1024))
    editBox:SetText(text)
    frame:Show()
    selectAll()
end

function ExportFrame.GetText()
    return currentText
end
