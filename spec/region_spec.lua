-- The WoW: Forever beta reports GetCurrentRegion() = 90 (portal "test",
-- GetCurrentRegionName() = ""), outside the contract's 1-5. Then, and only
-- then, the player's own choice (/rl region) is sent.
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

    it("on the beta (region 90) refuses until the player picks one, and says how", function()
        WowStub.state.region = 90
        local region, err = exportRegion(ns)
        assert.is_nil(region)
        assert.truthy(err:find("90", 1, true))
        assert.truthy(err:find("/rl region", 1, true))
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
