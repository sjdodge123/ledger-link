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

    -- RP-PvP (Raid Ledger ROK-2101): no in-game API marks the realm type, but
    -- live RP-PvP realms carry it in the name ("CAMWOW US2 Realm 9 RP PvP").
    it("sends rppvp when the realm name says RP PvP and the player hasn't picked one", function()
        WowStub.state.realmName = "CAMWOW US2 Realm 9 RP PvP"
        assert.equal("rppvp", exportRuleset(ns))
        assert.is_nil(LedgerLinkCharDB.ruleset) -- detected, not saved
        assert.equal("RP-PvP (detected)", ns.Identity.RulesetText())
        ns.HandleSlash("probe")
        assert.truthy(ns.ExportFrame.GetText():find("export sends: RP-PvP (detected)", 1, true))
    end)

    it("matches RP PvP as a whole word in any spelling, and nothing else", function()
        local is = ns.Identity.IsRpPvpRealmName
        for _, name in ipairs({ "Realm 9 RP PvP", "Realm 9 RP-PvP", "Realm 9 RPPvP", "Emerald Dream (RPPVP)",
            "rp pvp realm", "RP  PvP" }) do
            assert.is_true(is(name), name)
        end
        for _, name in ipairs({ "Classic Beta PvP", "Classic Beta PvE 2", "Tale Spinner", "Sharpvp", "RP PvPx",
            "Forever", "", nil, 42 }) do
            assert.is_false(is(name), tostring(name))
        end
    end)

    it("sends null on a realm whose name doesn't say RP PvP, or with no realm name", function()
        WowStub.state.realmName = "Classic Beta PvP"
        assert.equal(require("dkjson").null, exportRuleset(ns))
        local getRealmName = _G.GetRealmName
        _G.GetRealmName = nil
        assert.equal(require("dkjson").null, exportRuleset(ns))
        _G.GetRealmName = getRealmName
    end)

    it("hardcore wins over the realm name, and the player's pick over both", function()
        WowStub.state.realmName = "Realm 9 RP PvP"
        _G.C_GameRules = { IsHardcoreActive = function() return true end }
        assert.equal("hardcore", exportRuleset(ns))
        _G.C_GameRules = nil
        ns.HandleSlash("ruleset rp")
        assert.equal("roleplaying", exportRuleset(ns))
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
