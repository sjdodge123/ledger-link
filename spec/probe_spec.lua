-- /rl probe: one command that runs every beta check and shows the results in
-- the copy box, instead of the tester typing /dump lines.
local loadAddon = require("spec.support.load_addon")

local function probe(ns)
    ns.HandleSlash("probe")
    assert.is_true(WowStub.frames.LedgerLinkExportFrame.shown)
    return ns.ExportFrame.GetText()
end

describe("/rl probe", function()
    after_each(function()
        _G.C_GameRules, _G.GetCVar, _G.GetCurrentRegionName = nil, nil, nil
    end)

    it("reports each API's return values", function()
        local ns = loadAddon()
        WowStub.state.region = 90
        _G.GetCVar = function(name) if name == "portal" then return "test" end end
        _G.GetCurrentRegionName = function() return "" end
        local text = probe(ns)
        assert.truthy(text:find('GetCurrentRegion() = 90', 1, true), text)
        assert.truthy(text:find('GetCurrentRegionName() = ""', 1, true))
        assert.truthy(text:find('GetCVar("portal") = "test"', 1, true))
        assert.truthy(text:find('GetBuildInfo() = "1.60.1", "70009"', 1, true))
        assert.truthy(text:find('UnitGUID("player") = "Player-4395-0ABCDEF0"', 1, true))
        assert.truthy(text:find("LedgerLink " .. ns.VERSION, 1, true))
    end)

    it("says when a function is missing or errors, and keeps going", function()
        local ns = loadAddon()
        _G.C_GameRules = {
            IsHardcoreActive = function() return false end,
            GetForeverExperiencePreset = function() error("boom") end,
            GetCurrentGameModeDisplayInfo = function() return { name = "Forever", id = 7 } end,
        }
        local text = probe(ns)
        assert.truthy(text:find("C_GameRules.IsHardcoreActive() = false", 1, true))
        assert.truthy(text:find("C_GameRules.GetForeverExperiencePreset() = error:", 1, true))
        assert.truthy(text:find('C_GameRules.GetCurrentGameModeDisplayInfo() = {id = 7, name = "Forever"}', 1, true))
        assert.truthy(text:find("C_GameRules.GetActiveGameMode() = missing", 1, true))
        assert.truthy(text:find("GetCVar(\"portal\") = missing", 1, true))
        assert.truthy(text:find("C_Seasons = missing", 1, true))
    end)

    it("never includes a guild officer note", function()
        local ns = loadAddon()
        local text = probe(ns)
        assert.truthy(text:find("GetGuildRosterInfo(1)", 1, true))
        assert.truthy(text:find("public note", 1, true))
        assert.falsy(text:find("OFFICER SECRET", 1, true))
        assert.truthy(text:find("<officer note not read>", 1, true))
    end)

    it("is not offered as a Raid Ledger import", function()
        local ns = loadAddon()
        local text = probe(ns)
        assert.falsy(text:find("^!RL"))
        assert.truthy(ns.ExportFrame.GetFooter():find("paste", 1, true))
        assert.falsy(ns.ExportFrame.GetFooter():find("Import string", 1, true))
    end)
end)
