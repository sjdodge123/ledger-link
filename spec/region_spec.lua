-- The WoW: Forever beta reports GetCurrentRegion() = 90 (portal "test",
-- GetCurrentRegionName() = ""), outside the contract's 1-5. Then, and only
-- then, the player's own choice (/rl region) is sent, or, if they haven't
-- picked one, a region guessed from the game language (operator 2026-10-07:
-- players shouldn't have to type /rl region).
local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")

local function exportRegion(ns)
    local str, err = ns.Export.Run("char")
    if not str then return nil, err end
    return decode(str).payload.client.region
end

describe("region", function()
    local ns
    before_each(function() ns = loadAddon() end)

    it("uses GetCurrentRegion() when it is 1-5, even if the player set one", function()
        WowStub.state.region = 3
        ns.HandleSlash("region us")
        assert.equal(3, exportRegion(ns))
    end)

    it("on the beta guesses the region from the game language when none was picked", function()
        local cases = {
            enUS = 1, esMX = 1, ptBR = 1,
            enGB = 3, deDE = 3, frFR = 3, esES = 3, itIT = 3, ruRU = 3,
            koKR = 2, zhTW = 4,
            xxXX = 1, -- unknown language: US
        }
        for locale, id in pairs(cases) do
            WowStub.state.region = 90
            WowStub.state.locale = locale
            assert.equal(id, exportRegion(ns), locale)
        end
        assert.is_nil(LedgerLinkDB.region) -- a guess is never saved
    end)

    it("a picked region wins over the guess", function()
        WowStub.state.region = 90
        WowStub.state.locale = "deDE"
        ns.HandleSlash("region us")
        assert.equal(1, exportRegion(ns))
    end)

    it("says when the region was guessed, in /rl status and the panel", function()
        WowStub.state.region = 90
        WowStub.state.locale = "enGB"
        ns.HandleSlash("status")
        local said = false
        for _, line in ipairs(WowStub.printed) do
            said = said or line:find("Region: eu (guessed from your game language", 1, true) ~= nil
        end
        assert.is_true(said)
        ns.Panel.Show()
        assert.is_true(WowStub.frames.LedgerLinkPanelRegioneu.highlighted)
    end)

    it("on the beta sends the region the player picked", function()
        WowStub.state.region = 90
        for name, id in pairs({ us = 1, kr = 2, eu = 3, tw = 4, cn = 5 }) do
            ns.HandleSlash("region " .. name)
            assert.equal(id, exportRegion(ns), name)
        end
    end)

    it("is account-wide and survives a reload", function()
        WowStub.state.region = 90
        ns.HandleSlash("region eu")
        assert.equal("eu", LedgerLinkDB.region)
        local saved = LedgerLinkDB
        ns = loadAddon()
        WowStub.state.region = 90
        _G.LedgerLinkDB = saved
        ns.Init()
        assert.equal(3, exportRegion(ns))
    end)

    it("rejects an unknown region and keeps the old one", function()
        WowStub.state.region = 90
        ns.HandleSlash("region eu")
        ns.HandleSlash("region mars")
        assert.equal(3, exportRegion(ns))
        local usage = false
        for _, line in ipairs(WowStub.printed) do usage = usage or line:find("/rl region us|eu|kr|tw|cn", 1, true) ~= nil end
        assert.is_true(usage)
    end)

    it("shows in /rl status", function()
        WowStub.state.region = 90
        ns.HandleSlash("region us")
        ns.HandleSlash("status")
        local shown = false
        for _, line in ipairs(WowStub.printed) do shown = shown or line:find("Region: us", 1, true) ~= nil end
        assert.is_true(shown)
    end)
end)

-- Raid Ledger characters have no China region (WowRegionSchema is us/eu/kr/tw,
-- and WoW: Forever has no cn realms), so a cn string decodes and then fails at
-- import with REGION_MISMATCH. The wire format still allows 5, so cn stays
-- selectable, with a warning, from both the slash command and the panel.
describe("region cn", function()
    local function warned()
        for _, line in ipairs(WowStub.printed) do
            if line:find("can't import China", 1, true) then return true end
        end
        return false
    end

    it("warns that Raid Ledger can't import China-region characters (slash)", function()
        local ns = loadAddon()
        ns.HandleSlash("region cn")
        assert.equal("cn", LedgerLinkDB.region)
        assert.is_true(warned())
    end)

    it("warns from the panel's CN button too", function()
        local ns = loadAddon()
        WowStub.state.region = 90
        ns.Panel.Show()
        local b = WowStub.frames.LedgerLinkPanelRegioncn
        b.scripts.OnClick(b, "LeftButton")
        assert.equal("cn", LedgerLinkDB.region)
        assert.is_true(warned())
    end)

    it("doesn't warn for us/eu/kr/tw", function()
        local ns = loadAddon()
        for _, r in ipairs({ "us", "eu", "kr", "tw" }) do ns.HandleSlash("region " .. r) end
        assert.is_false(warned())
    end)
end)
