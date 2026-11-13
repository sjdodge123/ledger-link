-- Logout auto-export (Outbox.lua) from data cached while playing. Root cause
-- (2026-11-07, the operator's SavedVariables): at PLAYER_LOGOUT the client has
-- dropped the guild (GetGuildInfo("player") is nil, the roster is empty) and
-- the inventory + talent APIs return nothing, so every logout export had no
-- guild page, `gear: []` and empty talents. The roster, gear and talents read
-- while playing are now kept and used when the live read is empty. Wire format
-- unchanged (contract_spec validates the "all-logout-from-cache" case).
local loadAddon = require("spec.support.load_addon")
local importString = require("spec.support.import")

local GUID = "Player-4395-0ABCDEF0"

local function logout(ns)
    ns.Outbox.frame:GetScript("OnEvent")(ns.Outbox.frame, "PLAYER_LOGOUT")
    return LedgerLinkDB.outbox[GUID]
end

-- An event to every frame that registered it, the way the client delivers it.
local function fire(ns, event, ...)
    for _, frame in ipairs({ ns.Guild.frame, ns.Char.frame }) do
        if frame.events[event] then frame:GetScript("OnEvent")(frame, event, ...) end
    end
end

-- What the client reports once PLAYER_LOGOUT fires.
local function clientDropsEverything()
    local s = WowStub.state
    s.guild, s.guildRoster, s.gear, s.talentConfigId = nil, {}, {}, nil
end

local function bySection(text)
    local out = {}
    for _, g in ipairs(importString(text).groups) do out[g.section] = g end
    return out
end

local function guildData(group)
    local members = {}
    for _, p in ipairs(group.payloads) do
        for _, m in ipairs(p.data.members) do members[#members + 1] = m end
    end
    return group.payloads[1].data, members
end

describe("logout export from the play-time cache", function()
    local ns
    before_each(function()
        ns = loadAddon()
        fire(ns, "PLAYER_ENTERING_WORLD")
    end)

    it("registers the events it caches on", function()
        for _, e in ipairs({ "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD",
            "PLAYER_LEAVING_WORLD" }) do
            assert.is_true(ns.Guild.frame.events[e], e)
        end
        for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "PLAYER_EQUIPMENT_CHANGED",
            "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE" }) do
            assert.is_true(ns.Char.frame.events[e], e)
        end
    end)

    it("still has the guild page, gear, talents and guild name when the client dropped them", function()
        clientDropsEverything()
        local entry = logout(ns)
        assert.equal("all", entry.section)
        assert.equal("logout", entry.source)
        local groups = bySection(entry.text)
        local char = groups.char.payloads[1]
        assert.equal(2, #char.data.gear)
        assert.equal(16921, char.data.gear[1].itemId)
        assert.equal(7, char.data.talents.configId)
        assert.equal(3, #char.data.talents.nodes)
        assert.equal("Night Shift", char.who.guildName)
        assert.is_table(groups.guild)
        local data, members = guildData(groups.guild)
        assert.equal("Night Shift", data.name)
        assert.equal(3, #members)
        assert.equal("Night Shift", groups.guild.payloads[1].who.guildName)
    end)

    it("prefers the live read while the client still answers", function()
        WowStub.state.gear = { [5] = { id = 4444, link = "|cff1eff00|Hitem:4444::::::::60:::::|h[Vest]|h|r", ilvl = 40 } }
        WowStub.state.guildRoster = WowStub.roster(5)
        local entry = logout(ns)
        local groups = bySection(entry.text)
        assert.same({ 4444 }, { groups.char.payloads[1].data.gear[1].itemId })
        assert.equal(1, #groups.char.payloads[1].data.gear)
        local _, members = guildData(groups.guild)
        assert.equal(5, #members)
    end)

    it("keeps the roster as of the last GUILD_ROSTER_UPDATE, with that snapshotAt", function()
        local s = WowStub.state
        s.serverTime = s.serverTime + 60
        s.guildRoster = WowStub.roster(7)
        fire(ns, "GUILD_ROSTER_UPDATE")
        local readAt = s.serverTime
        s.serverTime = s.serverTime + 600
        clientDropsEverything()
        local data, members = guildData(bySection(logout(ns).text).guild)
        assert.equal(7, #members)
        assert.equal(readAt, data.snapshotAt)
    end)

    it("refreshes on GUILD_ROSTER_UPDATE at most every REFRESH_SECONDS; leaving the world always reads", function()
        local s = WowStub.state
        s.guildRoster = WowStub.roster(4)
        fire(ns, "GUILD_ROSTER_UPDATE") -- same second as PLAYER_ENTERING_WORLD: throttled
        assert.equal(3, #ns.Guild.cache.members)
        s.serverTime = s.serverTime + ns.Guild.REFRESH_SECONDS
        fire(ns, "GUILD_ROSTER_UPDATE")
        assert.equal(4, #ns.Guild.cache.members)
        s.guildRoster = WowStub.roster(6)
        fire(ns, "PLAYER_LEAVING_WORLD")
        assert.equal(6, #ns.Guild.cache.members)
    end)

    it("never sends the cached roster after the player left the guild", function()
        WowStub.state.guild, WowStub.state.guildRoster = nil, {}
        fire(ns, "PLAYER_GUILD_UPDATE", "player")
        assert.is_nil(ns.Guild.cache)
        clientDropsEverything()
        local entry = logout(ns)
        local groups = bySection(entry.text)
        assert.is_nil(groups.guild)
        assert.is_nil(groups.char.payloads[1].who.guildName)
        assert.equal(2, #groups.char.payloads[1].data.gear) -- gear still comes from the cache
    end)

    it("ignores a no-guild PLAYER_GUILD_UPDATE once the player is leaving the world", function()
        fire(ns, "PLAYER_LEAVING_WORLD")
        clientDropsEverything()
        fire(ns, "PLAYER_GUILD_UPDATE", "player")
        assert.is_table(bySection(logout(ns).text).guild)
    end)

    it("drops the cache on world entry when the guild was left during a loading screen", function()
        fire(ns, "PLAYER_LEAVING_WORLD")
        WowStub.state.guild, WowStub.state.guildRoster = nil, {}
        fire(ns, "PLAYER_GUILD_UPDATE", "player") -- ignored: leaving the world
        assert.is_table(ns.Guild.cache)
        fire(ns, "PLAYER_ENTERING_WORLD")
        assert.is_nil(ns.Guild.cache)
        assert.is_nil(ns.Guild.Name())
        clientDropsEverything()
        assert.is_nil(bySection(logout(ns).text).guild)
    end)

    it("drops the old roster when the client names another guild whose roster hasn't loaded", function()
        fire(ns, "PLAYER_LEAVING_WORLD")
        WowStub.state.guild, WowStub.state.guildRoster = "Day Shift", {}
        fire(ns, "PLAYER_ENTERING_WORLD")
        assert.is_nil(ns.Guild.cache)
        assert.equal("Day Shift", ns.Guild.Name())
        local pages, err = ns.Export.RunPages("guild")
        assert.is_nil(pages)
        assert.truthy(err:find("hasn't loaded", 1, true))
    end)

    it("never exports another guild's cached roster, even without an event", function()
        WowStub.state.guild, WowStub.state.guildRoster = "Day Shift", {}
        assert.is_nil(ns.Export.RunPages("guild"))
        assert.is_nil(ns.Guild.cache)
    end)

    it("ignores PLAYER_GUILD_UPDATE for other units", function()
        WowStub.state.guild = nil
        fire(ns, "PLAYER_GUILD_UPDATE", "party1")
        assert.is_table(ns.Guild.cache)
    end)

    it("joining a new guild replaces the cached roster", function()
        local s = WowStub.state
        s.guild, s.guildRoster = nil, {}
        fire(ns, "PLAYER_GUILD_UPDATE", "player")
        s.guild, s.guildRoster = "Day Shift", WowStub.roster(2)
        fire(ns, "PLAYER_GUILD_UPDATE", "player")
        clientDropsEverything()
        local data, members = guildData(bySection(logout(ns).text).guild)
        assert.equal("Day Shift", data.name)
        assert.equal(2, #members)
    end)

    it("drops public notes from the cached roster once /rl guildnotes is off", function()
        ns.HandleSlash("guildnotes on")
        fire(ns, "PLAYER_LEAVING_WORLD")
        assert.equal("public note 1", ns.Guild.cache.members[2].note)
        ns.HandleSlash("guildnotes off")
        clientDropsEverything()
        local group = bySection(logout(ns).text).guild
        local _, members = guildData(group)
        assert.equal(3, #members)
        for _, m in ipairs(members) do assert.is_nil(m.note) end
        for _, json in ipairs(group.jsons) do
            assert.is_nil(json:find("public note", 1, true))
            assert.is_nil(json:find("OFFICER", 1, true))
        end
    end)

    it("a guildless player gets no guild page", function()
        ns = loadAddon()
        WowStub.state.guild = nil
        fire(ns, "PLAYER_ENTERING_WORLD")
        clientDropsEverything()
        assert.is_nil(bySection(logout(ns).text).guild)
    end)

    it("PLAYER_EQUIPMENT_CHANGED keeps the newest gear", function()
        WowStub.state.gear[16] = nil
        WowStub.state.gear[17] = { id = 5555, link = "|cff0070dd|Hitem:5555::::::::60:::::|h[Shield]|h|r", ilvl = 60 }
        fire(ns, "PLAYER_EQUIPMENT_CHANGED", 16)
        clientDropsEverything()
        local gear = bySection(logout(ns).text).char.payloads[1].data.gear
        assert.equal(2, #gear)
        assert.equal(5555, gear[2].itemId)
    end)

    it("an empty read never replaces cached gear or talents", function()
        WowStub.state.gear, WowStub.state.talentConfigId = {}, nil
        fire(ns, "PLAYER_EQUIPMENT_CHANGED", 1)
        fire(ns, "TRAIT_CONFIG_UPDATED", 7)
        fire(ns, "PLAYER_LEAVING_WORLD")
        assert.equal(2, #ns.Char.cache.gear)
        assert.equal(7, ns.Char.cache.talents.configId)
    end)

    it("a config id with no readable nodes never replaces cached talents", function()
        WowStub.state.talentConfigId, WowStub.state.talentTrees = 9, {}
        fire(ns, "TRAIT_CONFIG_UPDATED", 9)
        assert.equal(7, ns.Char.cache.talents.configId)
        clientDropsEverything()
        local talents = bySection(logout(ns).text).char.payloads[1].data.talents
        assert.equal(7, talents.configId)
        assert.equal(3, #talents.nodes)
    end)

    it("talent changes refresh the cached talents", function()
        WowStub.state.talentConfigId = 9
        fire(ns, "TRAIT_CONFIG_UPDATED", 9)
        clientDropsEverything()
        assert.equal(9, bySection(logout(ns).text).char.payloads[1].data.talents.configId)
    end)

    it("with nothing cached (no world entry yet) it exports what the client gives, as before", function()
        ns = loadAddon()
        clientDropsEverything()
        local entry = logout(ns)
        assert.is_nil(bySection(entry.text).guild)
        assert.equal(0, #bySection(entry.text).char.payloads[1].data.gear)
    end)
end)

describe("/rl probe logout cache line", function()
    it("says what is cached, or none", function()
        local ns = loadAddon()
        assert.equal("logout cache: guild = none; gear = none; talents = none", ns.Probe.CacheLine())
        ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
        ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
        local line = ns.Probe.CacheLine()
        assert.truthy(line:find("guild = Night Shift, 3 members as of ", 1, true))
        -- The server has not sent the guild text yet: nothing read.
        assert.truthy(line:find(", motd unread, info unread; gear = 2 items; talents = 3 nodes", 1, true))
        assert.truthy(ns.Probe.Report():find(line, 1, true))
        ns.Guild.OnEvent("GUILD_MOTD", "Raid Thursday")
        assert.truthy(ns.Probe.CacheLine():find(", motd 77 bytes, info 95 bytes; gear = ", 1, true))
        WowStub.state.guildMotd, WowStub.state.guildInfoText = "Farm night", nil
        ns.Guild.OnEvent("PLAYER_LEAVING_WORLD")
        assert.truthy(ns.Probe.CacheLine():find(", motd 10 bytes, info unread; gear = ", 1, true))
    end)
end)
