-- /rl probe "S7" lines (operator 2026-10-13): the gamepad "More" menu on a bag
-- slot (Triangle), where a second addon wants a "Lock slot" entry. Static scan
-- of context-action labels, context/menu mixins and the Menu API, plus a
-- passive post-hook that records which menu opened (tag + entry texts).
local loadAddon = require("spec.support.load_addon")

local function report(ns)
    ns.HandleSlash("probe")
    return ns.ExportFrame.GetText()
end

local function has(text, needle)
    assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
end

local STUBBED = { "Menu", "MenuUtil", "hooksecurefunc", "CONTEXT_ACTION_LABEL_FOCUS", "ItemContextActionMixin" }

-- hooksecurefunc as the client does it: the original runs, then the hook, same arguments.
local function fakeHooksecurefunc(t, method, hook)
    local original = t[method]
    t[method] = function(...)
        local results = { original(...) }
        hook(...)
        return unpack(results)
    end
end

describe("/rl probe: S7 item menu", function()
    local saved
    before_each(function()
        saved = {}
        for _, name in ipairs(STUBBED) do saved[name] = rawget(_G, name) end
    end)
    after_each(function()
        for _, name in ipairs(STUBBED) do _G[name] = saved[name] end
    end)

    it("lists context-action labels, context mixins and the Menu API", function()
        local ns = loadAddon()
        _G.CONTEXT_ACTION_LABEL_FOCUS = "Focus"
        _G.ItemContextActionMixin = { AddAction = function() end }
        _G.Menu = { ModifyMenu = function() end, GetManager = function() return { menus = {} } end }
        local text = report(ns)
        has(text, 'S7 context action labels (1): CONTEXT_ACTION_LABEL_FOCUS="Focus"')
        has(text, "S7 mixin ItemContextActionMixin: AddAction")
        has(text, "S7 Menu functions: GetManager, ModifyMenu")
        has(text, "S7 MenuUtil functions: missing")
        has(text, "S7 Menu.GetManager() fields: menus(table)")
        has(text, "S7 menus opened this session: none recorded")
    end)

    it("records a menu the player opens, without changing it", function()
        local opened = {}
        local manager = { OpenContextMenu = function(_, owner, description) opened[#opened + 1] = { owner, description } end }
        _G.Menu = { GetManager = function() return manager end }
        _G.hooksecurefunc = fakeHooksecurefunc
        local ns = loadAddon()
        local owner = { [0] = "userdata", GetName = function() return "ContainerFrame1" end }
        local description = { tag = "MENU_ITEM_SLOT", elementDescriptions = { { text = "Use" }, { text = "Split Stack" } } }
        manager:OpenContextMenu(owner, description)
        assert.equal(1, #opened)
        assert.equal(description, opened[1][2])
        assert.same({ { text = "Use" }, { text = "Split Stack" } }, description.elementDescriptions)
        has(report(ns), 'S7 menu opened 1: Menu:OpenContextMenu owner=ContainerFrame1 tag="MENU_ITEM_SLOT"'
            .. ' entries: Use | Split Stack')
    end)

    it("installs nothing without the modern menu API", function()
        _G.hooksecurefunc = function() error("must not hook") end
        local ns = loadAddon()
        has(report(ns), "S7 Menu functions: missing")
    end)
end)
