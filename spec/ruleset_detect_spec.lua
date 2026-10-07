-- Ruleset auto-detection (2026-10-07). The client has no realm-type API, but
-- C_GameRules.IsHardcoreActive() exists on the WoW: Forever beta (false on a
-- PvP and a PvE realm; true on Hardcore is still unverified). When the player
-- hasn't picked a ruleset, a true result fills who.ruleset = "hardcore". The
-- player's own pick always wins. Missing or failing API = not detected.
local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")

local function exportRuleset(ns)
    return decode(assert(ns.Export.Run("char"))).payload.who.ruleset
end

local function printed(text)
    for _, line in ipairs(WowStub.printed) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

describe("ruleset detection", function()
    local ns
    before_each(function() ns = loadAddon() end)
    after_each(function() _G.C_GameRules = nil end)

    it("sends hardcore when the game says hardcore and the player hasn't picked one", function()
        _G.C_GameRules = { IsHardcoreActive = function() return true end }
        assert.equal("hardcore", exportRuleset(ns))
        assert.is_nil(LedgerLinkCharDB.ruleset) -- detected, not saved
    end)

    it("sends null when the game says not hardcore", function()
        _G.C_GameRules = { IsHardcoreActive = function() return false end }
        assert.equal(require("dkjson").null, exportRuleset(ns))
    end)

    it("sends null when the API is missing or errors", function()
        assert.equal(require("dkjson").null, exportRuleset(ns))
        _G.C_GameRules = {}
        assert.equal(require("dkjson").null, exportRuleset(ns))
        _G.C_GameRules = { IsHardcoreActive = function() error("nope") end }
        assert.equal(require("dkjson").null, exportRuleset(ns))
        _G.C_GameRules = { IsHardcoreActive = function() return "yes" end } -- only a real true counts
        assert.equal(require("dkjson").null, exportRuleset(ns))
    end)

    it("lets the player's own pick win", function()
        _G.C_GameRules = { IsHardcoreActive = function() return true end }
        ns.HandleSlash("ruleset pvp")
        assert.equal("pvp", exportRuleset(ns))
    end)

    it("shows the detected ruleset in the panel, tooltip and /rl status", function()
        _G.C_GameRules = { IsHardcoreActive = function() return true end }
        ns.Panel.Show()
        assert.is_true(WowStub.frames.LedgerLinkPanelRulesethardcore.highlighted)
        local b = WowStub.frames.LedgerLinkMinimapButton
        b.scripts.OnEnter(b)
        assert.truthy(table.concat(GameTooltip.lines, "\n"):find("hardcore (detected)", 1, true))
        ns.HandleSlash("status")
        assert.is_true(printed("Ruleset: hardcore (detected)"))
    end)
end)
