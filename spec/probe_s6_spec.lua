-- /rl probe "S6" lines: Forever's built-in gamepad UI ("smart navigation").
-- The first report (v1.3.1, 2026-10-13) found gamepadFooter tables, footer
-- "inputLegend" frames, smartNavigationFocusKey, C_Navigation and gamepad
-- mixins; these lines look inside them. Read-only: nothing found is called.
local loadAddon = require("spec.support.load_addon")

local function report(ns)
    ns.HandleSlash("probe")
    return ns.ExportFrame.GetText()
end

local function has(text, needle)
    assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
end

local STUBBED = { "MailFrame", "InboxFrame", "SendMailFrame", "OpenMailFrame", "GamepadFocusFrameMixin",
    "InputPromptMixin", "BankPanelMixin", "C_Navigation", "InputPromptLegends", "ConsoleGetAllCommands", "GetCVar" }

local function frame(name, fields)
    fields = fields or {}
    fields[0] = "userdata"
    fields.GetName = fields.GetName or function() return name end
    return fields
end

describe("/rl probe: S6 smart navigation", function()
    local ns, saved, called
    before_each(function()
        ns = loadAddon()
        saved = {}
        for _, name in ipairs(STUBBED) do saved[name] = rawget(_G, name) end
        called = 0
    end)
    after_each(function()
        for _, name in ipairs(STUBBED) do _G[name] = saved[name] end
    end)

    it("dumps the footer tables and legend frames without calling their callbacks", function()
        local legend = frame("InboxLegend", { SetPrompts = function() called = called + 1 end })
        _G.InboxFrame = frame("InboxFrame", {
            smartNavigationFocusKey = "inbox",
            InboxFooterinputLegend = legend,
            gamepadFooter = {
                { button = "PAD3", label = "Open All", callback = function() called = called + 1 end, frame = legend },
            },
        })
        _G.MailFrame = frame("MailFrame", { isFocused = true, selectedTab = 1, FocusJumpHint = frame("Hint") })
        local text = report(ns)
        has(text, 'S6 InboxFrame.gamepadFooter = {1 = {button = "PAD3", callback = function, frame = <frame InboxLegend>,'
            .. ' label = "Open All"}}')
        has(text, 'S6 InboxFrame.smartNavigationFocusKey = "inbox"')
        has(text, "S6 frame InboxFrame.InboxFooterinputLegend fields: GetName(function), SetPrompts(function)")
        has(text, "S6 SendMailFrame.gamepadFooter = nil")
        has(text, "S6 frame SendMailFrame.SendMailFooterinputLegend = missing")
        has(text, "S6 MailFrame.isFocused = true")
        has(text, "S6 MailFrame.FocusJumpHint = <frame Hint>")
        assert.equal(0, called)
    end)

    it("lists gamepad mixins, by name or by the gamepad methods they carry", function()
        _G.GamepadFocusFrameMixin = { StartFocus = function() end, LockInFocus = function() end }
        _G.InputPromptMixin = { SetPrompt = function() end }
        _G.BankPanelMixin = { FocusGamepad = function() end, Refresh = function() end }
        local text = report(ns)
        has(text, "S6 mixin BankPanelMixin: FocusGamepad, Refresh")
        has(text, "S6 mixin GamepadFocusFrameMixin: LockInFocus, StartFocus")
        has(text, "S6 mixin InputPromptMixin: SetPrompt")
    end)

    it("lists navigation namespaces, the button legend table and CVars", function()
        _G.C_Navigation = { GetFocusedFrame = function() called = called + 1 end }
        _G.InputPromptLegends = { PAD1 = { atlas = "Gamepad_Cross" } }
        _G.ConsoleGetAllCommands = function() return { { command = "GamePadEnable" }, { command = "Sound_Volume" } } end
        _G.GetCVar = function(name) return name == "GamePadEnable" and "1" or nil end
        local text = report(ns)
        has(text, "S6 C_Navigation functions: GetFocusedFrame")
        has(text, 'S6 InputPromptLegends = {PAD1 = {atlas = "Gamepad_Cross"}}')
        has(text, "S6 CVars matching gamepad|cursor|smartnav (1): GamePadEnable=1")
        assert.equal(0, called)
    end)

    it("still completes with none of it present", function()
        local text = report(ns)
        has(text, "S6 frame MailFrame = missing")
        has(text, "S6 InboxFrame.gamepadFooter = nil")
        has(text, "S6 CVars: GetAllCommands missing")
    end)
end)
