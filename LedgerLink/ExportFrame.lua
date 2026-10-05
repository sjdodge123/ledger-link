-- Copyable export window (WeakAuras/Details pattern): a movable frame with
-- a read-only-feeling multi-line EditBox and Escape to close. The addon never
-- moves keyboard focus itself (no SetFocus): on the beta, doing that while the
-- game was handling the /rl chat command made the gamepad UI call
-- SetPreferredGamepadInteractTarget() inside the addon's call chain, which the
-- game blocks ("blocked from an action only available to the Blizzard UI") and
-- then crashed. The player clicks the text instead; that selects all of it.
local _, ns = ...

local ExportFrame = {}
ns.ExportFrame = ExportFrame

local frame, editBox, title, sizeLabel, pageLabel, hintLabel, prevButton, nextButton
local currentText = ""
local pages, pageIndex, currentSection, footer = {}, 1, "", nil

--- Shown above a multi-page export.
ExportFrame.PAGE_HINT = "Copy every page (Next >). Raid Ledger accepts all pages pasted into one box, in any order."

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
    -- A click also moves the cursor, which would drop the selection.
    box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    scroll:SetScrollChild(box)
    return box
end

local function createButtons(parent)
    prevButton = ns.UI.Button(parent, "< Prev", 70, function() ExportFrame.PrevPage() end)
    prevButton:SetPoint("BOTTOMLEFT", 20, 16)
    nextButton = ns.UI.Button(parent, "Next >", 70, function() ExportFrame.NextPage() end)
    nextButton:SetPoint("BOTTOMLEFT", 170, 16)
    pageLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pageLabel:SetPoint("BOTTOMLEFT", 95, 21)
end

local function create()
    local f = ns.UI.Window("LedgerLinkExportFrame", 600, 400)
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
    editBox:HighlightText()
end

ExportFrame.DEFAULT_FOOTER = "Click the text, Ctrl+C, then paste into Raid Ledger -> Import string"

--- Show one string, or a list of page strings, for `section`; the (first)
--- page is pre-selected for Ctrl+C. `footerText` replaces the default hint.
function ExportFrame.Show(section, textOrPages, footerText)
    if not frame then create() end
    pages = type(textOrPages) == "table" and textOrPages or { textOrPages }
    pageIndex, currentSection, footer = 1, section, footerText
    -- One window at a time: the panel steps aside for the export.
    if ns.Panel then ns.Panel.Hide() end
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
