-- /rl probe "S6" lines (operator screenshot 2026-10-13): Forever's built-in
-- gamepad UI (L2/R2 cycle windows, L1/R1 tabs, a footer of glyph hints). Global
-- names, gamepad-named tables' functions, mail frame fields and children, and
-- gamepad/cursor CVars. Read-only: nothing found is called.
local loadAddon = require("spec.support.load_addon")

local function report(ns)
    ns.HandleSlash("probe")
    return ns.ExportFrame.GetText()
end

local function has(text, needle)
    assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
end

local STUBBED = { "GamePadFooterMixin", "GamePadGlyphs", "MailFrame", "C_Console", "GetCVar" }

describe("/rl probe: S6 native gamepad UI discovery", function()
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

    it("lists gamepad-named globals and their tables' functions without calling them", function()
        _G.GamePadFooterMixin = {
            SetActions = function() called = called + 1 end,
            OnShow = function() called = called + 1 end,
            label = "footer",
        }
        _G.GamePadGlyphs = { Cross = "Interface\\Glyph\\Cross" }
        local text = report(ns)
        has(text, "S6 globals matching gamepad: GamePadFooterMixin(table), GamePadGlyphs(table)")
        has(text, "S6 globals matching footer: GamePadFooterMixin(table)")
        has(text, "S6 table GamePadFooterMixin functions (2): OnShow, SetActions")
        has(text, "S6 table GamePadGlyphs functions (0): ")
        assert.equal(0, called)
    end)

    it("lists the mail frame's own fields and child frame names", function()
        local child = { GetName = function() return "MailFrameFooter" end }
        local anon = { GetName = function() return nil end, GetDebugName = function() return "MailFrame.Hints" end }
        _G.MailFrame = {
            [0] = "userdata",
            gamepadActions = {},
            OpenAll = function() called = called + 1 end,
            GetChildren = function() return child, anon end,
        }
        local text = report(ns)
        has(text, "S6 frame MailFrame fields: GetChildren(function), OpenAll(function), gamepadActions(table)")
        has(text, "S6 frame MailFrame children (2): MailFrameFooter, (MailFrame.Hints)")
        has(text, "S6 frame SendMailFrame = missing")
        assert.equal(0, called)
    end)

    it("reports gamepad and cursor CVars with their values", function()
        _G.C_Console = { GetAllCommands = function()
            return { { command = "GamePadEnable" }, { command = "GamePadCursorAutoEnable" }, { command = "Sound_Volume" } }
        end }
        _G.GetCVar = function(name) return ({ GamePadEnable = "1", GamePadCursorAutoEnable = "0" })[name] end
        local text = report(ns)
        has(text, "S6 CVars matching gamepad|cursor (2): GamePadCursorAutoEnable=0, GamePadEnable=1")
    end)

    it("still completes with none of it present", function()
        local text = report(ns)
        has(text, "S6 frame MailFrame = missing")
        has(text, "S6 CVars: C_Console.GetAllCommands missing")
    end)
end)
