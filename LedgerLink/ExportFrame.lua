-- Copyable export window (WeakAuras/Details pattern): a movable frame with
-- a read-only-feeling multi-line EditBox, pre-selected text and Escape to close.
local _, ns = ...

local ExportFrame = {}
ns.ExportFrame = ExportFrame

local frame, editBox, title, sizeLabel, pageLabel, hintLabel, prevButton, nextButton
local currentText = ""
local pages, pageIndex, currentSection, footer = {}, 1, "", nil

--- Shown above a multi-page export.
ExportFrame.PAGE_HINT = "Copy every page (Next >). Raid Ledger accepts all pages pasted into one box, in any order."

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
    scroll:SetPoint("TOPLEFT", 20, -58)
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

local function button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function createButtons(parent)
    button(parent, "Select all", 100, selectAll):SetPoint("BOTTOMLEFT", 20, 16)
    prevButton = button(parent, "< Prev", 70, function() ExportFrame.PrevPage() end)
    prevButton:SetPoint("BOTTOMLEFT", 130, 16)
    nextButton = button(parent, "Next >", 70, function() ExportFrame.NextPage() end)
    nextButton:SetPoint("BOTTOMLEFT", 280, 16)
    pageLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pageLabel:SetPoint("BOTTOMLEFT", 205, 21)
    local close = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
end

local function create()
    local ok, f = pcall(CreateFrame, "Frame", "LedgerLinkExportFrame", UIParent, "BackdropTemplate")
    if not ok then f = CreateFrame("Frame", "LedgerLinkExportFrame", UIParent) end
    f:SetSize(600, 400)
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
    hintLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hintLabel:SetPoint("TOP", 0, -40)
    hintLabel:SetText(ExportFrame.PAGE_HINT)
    frame = f
    editBox = createEditBox(f)
    createButtons(f)
    -- Escape closes the window even when the edit box isn't focused.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "LedgerLinkExportFrame")
    end
end

local function setShown(widget, shown)
    if shown then widget:Show() else widget:Hide() end
end

local function render()
    local count = #pages
    currentText = pages[pageIndex] or ""
    local paged = count > 1
    title:SetText("Ledger Link - " .. currentSection .. " export")
    pageLabel:SetText(paged and string.format("Page %d/%d", pageIndex, count) or "")
    setShown(pageLabel, paged)
    setShown(hintLabel, paged)
    setShown(prevButton, paged)
    setShown(nextButton, paged)
    if prevButton.SetEnabled then prevButton:SetEnabled(pageIndex > 1) end
    if nextButton.SetEnabled then nextButton:SetEnabled(pageIndex < count) end
    sizeLabel:SetText(string.format("%.1f KB - %s", #currentText / 1024, ExportFrame.GetFooter()))
    editBox:SetText(currentText)
    selectAll()
end

ExportFrame.DEFAULT_FOOTER = "Ctrl+C, then paste into Raid Ledger -> Import string"

--- Show one string, or a list of page strings, for `section`; the (first)
--- page is pre-selected for Ctrl+C. `footerText` replaces the default hint.
function ExportFrame.Show(section, textOrPages, footerText)
    if not frame then create() end
    pages = type(textOrPages) == "table" and textOrPages or { textOrPages }
    pageIndex, currentSection, footer = 1, section, footerText
    frame:Show()
    render()
end

function ExportFrame.NextPage()
    if pageIndex < #pages then
        pageIndex = pageIndex + 1
        render()
    end
end

function ExportFrame.PrevPage()
    if pageIndex > 1 then
        pageIndex = pageIndex - 1
        render()
    end
end

--- Current page number and page count.
function ExportFrame.GetPage()
    return pageIndex, #pages
end

function ExportFrame.GetFooter()
    return footer or ExportFrame.DEFAULT_FOOTER
end

function ExportFrame.GetPageLabel()
    return pageLabel and pageLabel:GetText() or ""
end

--- Text of the page currently shown.
function ExportFrame.GetText()
    return currentText
end
