-- C_GuildInfo.GetMOTD / GetInfoText are HasRestrictions APIs: while the game
-- enforces an addon restriction it blocks them (ADDON_ACTION_BLOCKED "read()",
-- 2026-11-11, from the background roster refresh, three times in chat). The
-- addon skips the reads while a restriction is on, backs off after a block,
-- keeps the text it last read, and announces a blocked function once.
local loadAddon = require("spec.support.load_addon")

local function printedCount(text)
    local n = 0
    for _, line in ipairs(WowStub.printed) do
        if line:find(text, 1, true) then n = n + 1 end
    end
    return n
end

describe("guild text reads under addon restrictions", function()
    local ns, readers, calls
    local saved = {}

    before_each(function()
        ns = loadAddon()
        -- The guild text has loaded (spec/guild_text_loaded_spec.lua), but
        -- start from nothing read.
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        ns.Guild.cache = nil
        for k, v in pairs(_G.C_GuildInfo) do saved[k] = v end
        calls = { GetMOTD = 0, GetInfoText = 0 }
        readers = {}
        for _, method in ipairs({ "GetMOTD", "GetInfoText" }) do
            readers[method] = _G.C_GuildInfo[method]
            _G.C_GuildInfo[method] = function()
                calls[method] = calls[method] + 1
                return readers[method]()
            end
        end
    end)
    after_each(function()
        _G.C_GuildInfo = {}
        for k, v in pairs(saved) do _G.C_GuildInfo[k] = v end
        _G.GetGuildRosterMOTD = nil
    end)

    local function refresh() assert.is_true(ns.Guild.Refresh(true)) end

    it("reads both boxes when no restriction is on", function()
        refresh()
        assert.same({ GetMOTD = 1, GetInfoText = 1 }, calls)
        assert.equal(77, #ns.Guild.cache.motd)
    end)

    for _, case in ipairs({
        { "combat lockdown", function(s) s.inCombat = true end },
        { "an encounter", function(s) s.restrictions[Enum.AddOnRestrictionType.Encounter] = true end },
        { "a restricted map", function(s) s.restrictions[Enum.AddOnRestrictionType.Map] = true end },
        { "chat lockdown", function(s) s.restrictions[Enum.AddOnRestrictionType.Chat] = true end },
    }) do
        it("skips both reads during " .. case[1] .. " and keeps the text last read", function()
            refresh()
            local motd, info = ns.Guild.cache.motd, ns.Guild.cache.infoText
            WowStub.state.guildMotd = "changed while restricted"
            case[2](WowStub.state)
            refresh()
            assert.same({ GetMOTD = 1, GetInfoText = 1 }, calls)
            assert.equal(motd, ns.Guild.cache.motd)
            assert.equal(info, ns.Guild.cache.infoText)
            assert.equal(3, #ns.Guild.cache.members) -- the roster still refreshes
        end)
    end

    it("leaves the keys out when a restriction is on before anything was read", function()
        WowStub.state.restrictions[Enum.AddOnRestrictionType.Encounter] = true
        refresh()
        assert.same({ GetMOTD = 0, GetInfoText = 0 }, calls)
        assert.is_nil(ns.Guild.cache.motd)
        assert.is_nil(ns.Guild.cache.infoText)
    end)

    it("after a block: stops (no alias, no info read), keeps the old text, retries later", function()
        refresh()
        local motd = ns.Guild.cache.motd
        local aliasCalls = 0
        _G.GetGuildRosterMOTD = function() aliasCalls = aliasCalls + 1 return "alias" end
        readers.GetMOTD = function()
            -- The client fires the block event during the call, then returns nothing.
            ns.Blocked.OnEvent("ADDON_ACTION_BLOCKED", "LedgerLink", "readGuildText()")
        end
        refresh()
        assert.same({ GetMOTD = 2, GetInfoText = 1 }, calls)
        assert.equal(0, aliasCalls)
        assert.equal(motd, ns.Guild.cache.motd)
        assert.equal(1, #LedgerLinkDB.blocked)

        WowStub.state.serverTime = WowStub.state.serverTime + ns.Guild.TEXT_RETRY_SECONDS - 1
        refresh()
        assert.same({ GetMOTD = 2, GetInfoText = 1 }, calls) -- still backing off

        WowStub.state.serverTime = WowStub.state.serverTime + 1
        readers.GetMOTD = function() return "new motd" end
        refresh()
        assert.same({ GetMOTD = 3, GetInfoText = 2 }, calls)
        assert.equal("new motd", ns.Guild.cache.motd)
    end)
end)

describe("blocked-action chat notice", function()
    it("is printed once per blocked function per session; every block is recorded", function()
        local ns = loadAddon()
        for _ = 1, 3 do ns.Blocked.OnEvent("ADDON_ACTION_BLOCKED", "LedgerLink", "read()") end
        ns.Blocked.OnEvent("ADDON_ACTION_BLOCKED", "LedgerLink", "Other()")
        assert.equal(1, printedCount("The game blocked read()"))
        assert.equal(1, printedCount("The game blocked Other()"))
        assert.equal(4, #LedgerLinkDB.blocked)
        assert.equal(4, ns.Blocked.count)
    end)
end)

describe("/rl probe addon restrictions line", function()
    it("names the active restrictions, or none", function()
        local ns = loadAddon()
        assert.equal("addon restrictions: none", ns.Blocked.RestrictionLine())
        WowStub.state.inCombat = true
        WowStub.state.restrictions[Enum.AddOnRestrictionType.Map] = true
        WowStub.state.restrictions[Enum.AddOnRestrictionType.Encounter] = true
        local line = ns.Blocked.RestrictionLine()
        assert.equal("addon restrictions: combat lockdown, Encounter, Map", line)
        assert.truthy(ns.Probe.Report():find(line, 1, true))
    end)

    it("says when the client has no restriction API", function()
        local ns = loadAddon()
        local api = _G.C_RestrictedActions
        _G.C_RestrictedActions = nil
        local line = ns.Blocked.RestrictionLine()
        _G.C_RestrictedActions = api
        assert.equal("addon restrictions: none (C_RestrictedActions.IsAddOnRestrictionActive missing)", line)
    end)
end)
