-- The guild export's `motd` / `infoText` are sent only once the server has
-- sent the guild text this session. 2026-11-13, during a Blizzard outage: an
-- export carried motd = "" and infoText = "" (C_GuildInfo.GetMOTD /
-- GetInfoText read "" while disconnected or before the guild data arrived) and
-- Raid Ledger stored them as NULL, wiping the guild's synced text. Until the
-- text has loaded both keys are left out, which contract v1 reads as "no
-- opinion" (ROK-2137). A GUILD_MOTD, or a GUILD_ROSTER_UPDATE with a populated
-- roster, while in a named guild, marks it loaded.
local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")
local importString = require("spec.support.import")

local GUID = "Player-4395-0ABCDEF0"
local MOTD = "Raid Thursday 20:00 server time - |cffff8000Molten Core|r. Bring fire resist!"

local function page1(ns)
    return decode(assert(ns.Export.RunPages("guild"))[1])
end

local function assertNoText(page)
    assert.is_nil(page.payload.data.motd)
    assert.is_nil(page.payload.data.infoText)
    assert.is_nil(page.json:find('"motd"', 1, true))
    assert.is_nil(page.json:find('"infoText"', 1, true))
end

local function logoutGuildData(ns)
    local s = WowStub.state
    s.guild, s.guildRoster, s.guildMotd, s.guildInfoText = nil, {}, nil, nil
    ns.Outbox.frame:GetScript("OnEvent")(ns.Outbox.frame, "PLAYER_LOGOUT")
    for _, group in ipairs(importString(LedgerLinkDB.outbox[GUID].text).groups) do
        if group.section == "guild" then return group.payloads[1].data end
    end
    error("the logout export has no guild section")
end

describe("guild text: sent only once loaded from the server", function()
    local ns
    before_each(function() ns = loadAddon() end)

    it("registers GUILD_MOTD", function()
        assert.is_true(ns.Guild.frame.events.GUILD_MOTD)
    end)

    it("leaves both keys out before any server signal, though the roster exports", function()
        local page = page1(ns)
        assertNoText(page)
        assert.equal(3, #page.payload.data.members)
    end)

    it("leaves both keys out for outage-style empty reads before load (the 2026-11-13 wipe)", function()
        WowStub.state.guildMotd, WowStub.state.guildInfoText = "", ""
        ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
        assertNoText(page1(ns))
        -- A roster update with the guild data dropped is not a load either.
        local roster = WowStub.state.guildRoster
        WowStub.state.guildRoster = {}
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        WowStub.state.guildRoster = roster
        assertNoText(page1(ns))
    end)

    it("does not count a roster update while not in a guild, or with no guild name", function()
        WowStub.state.guild = nil
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        ns.Guild.OnEvent("GUILD_MOTD", "")
        WowStub.state.guild = "Night Shift"
        assertNoText(page1(ns))
        WowStub.state.guild = ""
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        WowStub.state.guild = "Night Shift"
        assertNoText(page1(ns))
    end)

    it("sends the text once a populated GUILD_ROSTER_UPDATE arrived", function()
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        local data = page1(ns).payload.data
        assert.equal(MOTD, data.motd)
        assert.truthy(data.infoText:find("casual Forever guild", 1, true))
    end)

    it("sends the text once GUILD_MOTD arrived, even before the roster update", function()
        ns.Guild.OnEvent("GUILD_MOTD", MOTD)
        assert.equal(MOTD, page1(ns).payload.data.motd)
    end)

    it("sends \"\" when an officer clears the MOTD after load (GUILD_MOTD \"\")", function()
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        assert.equal(MOTD, ns.Guild.cache.motd)
        WowStub.state.guildMotd = ""
        ns.Guild.OnEvent("GUILD_MOTD", "")
        assert.equal("", ns.Guild.cache.motd)
        local page = page1(ns)
        assert.equal("", page.payload.data.motd)
        assert.truthy(page.json:find('"motd":""', 1, true))
    end)

    it("sends \"\" for a guild whose boxes really are empty, once loaded", function()
        WowStub.state.guildMotd, WowStub.state.guildInfoText = "", ""
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        local data = page1(ns).payload.data
        assert.equal("", data.motd)
        assert.equal("", data.infoText)
    end)

    it("after the client drops the guild data, keeps the last text instead of a blank read", function()
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        local roster = WowStub.state.guildRoster
        WowStub.state.guildRoster = {}
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE") -- unloaded again
        WowStub.state.guildRoster = roster
        WowStub.state.guildMotd, WowStub.state.guildInfoText = "", ""
        local data = page1(ns).payload.data
        assert.equal(MOTD, data.motd)
        assert.truthy(data.infoText:find("casual Forever guild", 1, true))
    end)

    it("does not carry the loaded state to a different guild", function()
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        WowStub.state.guild = "Day Shift"
        WowStub.state.guildMotd, WowStub.state.guildInfoText = "", ""
        assertNoText(page1(ns))
    end)

    it("still skips the reads under an addon restriction, keeping the text last read", function()
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        WowStub.state.inCombat = true
        WowStub.state.guildMotd = ""
        assert.equal(MOTD, page1(ns).payload.data.motd)
    end)

    describe("leaving the world (logout or a disconnect)", function()
        it("never lets a \"\" read there blank a box that held text", function()
            ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
            WowStub.state.guildMotd, WowStub.state.guildInfoText = "", ""
            ns.Guild.OnEvent("PLAYER_LEAVING_WORLD")
            local data = logoutGuildData(ns)
            assert.equal(MOTD, data.motd)
            assert.truthy(data.infoText:find("casual Forever guild", 1, true))
        end)

        it("still takes a changed, non-empty text there", function()
            ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
            WowStub.state.guildMotd = "Raid moved to Friday"
            ns.Guild.OnEvent("PLAYER_LEAVING_WORLD")
            assert.equal("Raid moved to Friday", logoutGuildData(ns).motd)
        end)

        it("leaves the keys out when the text never loaded this session", function()
            ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
            WowStub.state.guildMotd, WowStub.state.guildInfoText = "", ""
            ns.Guild.OnEvent("PLAYER_LEAVING_WORLD")
            local data = logoutGuildData(ns)
            assert.is_nil(data.motd)
            assert.is_nil(data.infoText)
            assert.equal(3, #data.members)
        end)
    end)

    it("says in /rl probe whether the text has loaded, and what loaded it", function()
        assert.truthy(ns.Probe.Report():find("guild text: not loaded", 1, true))
        ns.Guild.OnEvent("GUILD_MOTD", "")
        assert.equal("guild text: loaded (GUILD_MOTD)", ns.Guild.TextStateLine())
        assert.truthy(ns.Probe.Report():find("guild text: loaded (GUILD_MOTD)", 1, true))
        WowStub.state.guild = nil
        ns.Guild.OnEvent("PLAYER_GUILD_UPDATE", "player")
        WowStub.state.guild = "Night Shift"
        assert.truthy(ns.Guild.TextStateLine():find("not loaded", 1, true))
    end)
end)
