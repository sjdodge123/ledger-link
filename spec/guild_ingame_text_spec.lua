-- The guild export's `motd` / `infoText` (Raid Ledger ROK-2137, contract v1
-- CONTRACT.md §guild): the in-game Message of the Day (<= 255 UTF-16 units)
-- and Guild Information (<= 499), verbatim. "" = the box is empty; an absent
-- key = "no opinion" (the read failed), and the server keeps what it stored.
-- Schema validation of these exports is in spec/contract_spec.lua (the
-- "guild-text-*" cases of spec/support/export_cases.lua).
local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")
local importString = require("spec.support.import")
local dkjson = require("dkjson")

local GUID = "Player-4395-0ABCDEF0"

local function fixtureData()
    local f = assert(io.open("contract/v1/fixtures/guild-ingame-text.json"))
    local data = dkjson.decode(f:read("*a")).payload.data
    f:close()
    return data
end

local function pagesOf(ns)
    local decoded = {}
    for i, page in ipairs(assert(ns.Export.RunPages("guild"))) do decoded[i] = decode(page) end
    return decoded
end

local function exported(ns)
    return pagesOf(ns)[1].payload.data
end

-- JSON string length as the server counts it (UTF-16 code units).
local function utf16Units(s)
    local units = 0
    for lead in s:gmatch("[%z\1-\127\192-\255]") do units = units + (lead:byte() >= 0xF0 and 2 or 1) end
    return units
end

-- The roster dropped by the client at PLAYER_LOGOUT, then the auto-export.
local function logoutGuildPages(ns)
    local s = WowStub.state
    s.guild, s.guildRoster, s.guildMotd, s.guildInfoText = nil, {}, nil, nil
    ns.Outbox.frame:GetScript("OnEvent")(ns.Outbox.frame, "PLAYER_LOGOUT")
    local entry = assert(LedgerLinkDB.outbox[GUID], "no logout outbox entry")
    assert.equal("logout", entry.source)
    for _, group in ipairs(importString(entry.text).groups) do
        if group.section == "guild" then return group.payloads end
    end
    error("the logout export has no guild section")
end

describe("guild export: in-game Message of the Day and Guild Information", function()
    local ns
    local readers = {}
    for k, v in pairs(_G.C_GuildInfo) do readers[k] = v end
    before_each(function()
        ns = loadAddon()
        -- The server has sent the guild data, so the text has loaded
        -- (spec/guild_text_loaded_spec.lua covers before it has).
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
    end)
    -- Tests below remove or replace the client's readers: put them back.
    after_each(function()
        _G.C_GuildInfo = {}
        for k, v in pairs(readers) do _G.C_GuildInfo[k] = v end
        _G.issecretvalue, _G.GetGuildRosterMOTD, _G.GetGuildInfoText = nil, nil, nil
    end)

    it("sends both boxes verbatim, colour codes and newlines kept", function()
        local want = fixtureData()
        local data = exported(ns)
        assert.equal(want.motd, data.motd)
        assert.equal(want.infoText, data.infoText)
        assert.truthy(data.motd:find("|cffff8000Molten Core|r", 1, true))
        assert.truthy(data.infoText:find("\n", 1, true))
        assert.equal(false, data.canViewOfficerNote)
    end)

    it("reproduces the guild-ingame-text fixture's data", function()
        local want = fixtureData()
        local s = WowStub.state
        s.realmName = "" -- the fixture has no rawRealm
        s.guildRoster = {
            WowStub.member(0, { guid = GUID, name = "Ana Forever", class = "PALADIN", note = "" }),
            WowStub.member(1, { guid = "Player-4395-00000001", name = "Member1", note = "Main tank" }),
            WowStub.member(2, { guid = "Player-4395-00000002", name = "Member2", note = "" }),
        }
        LedgerLinkDB.guildNotes = true
        assert.same(want, exported(ns))
    end)

    it("sends \"\" for an empty box, and still sends the other one", function()
        WowStub.state.guildMotd = ""
        local data = exported(ns)
        assert.equal("", data.motd)
        assert.equal(fixtureData().infoText, data.infoText)
        WowStub.state.guildMotd, WowStub.state.guildInfoText = "Farm night", ""
        data = exported(ns)
        assert.equal("Farm night", data.motd)
        assert.equal("", data.infoText)
    end)

    it("leaves the key out when the read fails; never \"\" for \"could not read\"", function()
        WowStub.state.guildMotd = nil -- C_GuildInfo.GetMOTD raises
        local page = pagesOf(ns)[1]
        assert.is_nil(page.payload.data.motd)
        assert.is_nil(page.json:find('"motd"', 1, true))
        assert.equal(fixtureData().infoText, page.payload.data.infoText)
        WowStub.state.guildInfoText = nil
        page = pagesOf(ns)[1]
        assert.is_nil(page.json:find('"motd"', 1, true))
        assert.is_nil(page.json:find('"infoText"', 1, true))
        assert.equal(3, #page.payload.data.members) -- the roster still exports
    end)

    it("leaves the key out when the read API is missing or returns something that is not text", function()
        _G.C_GuildInfo.GetMOTD = nil
        _G.C_GuildInfo.GetInfoText = function() return 42 end
        local data = exported(ns)
        assert.is_nil(data.motd)
        assert.is_nil(data.infoText)
        _G.C_GuildInfo = nil
        data = exported(ns)
        assert.is_nil(data.motd)
        assert.is_nil(data.infoText)
    end)

    it("leaves the key out for a secret value", function()
        local secret = WowStub.state.guildMotd
        _G.issecretvalue = function(v) return v == secret end
        local data = exported(ns)
        assert.is_nil(data.motd)
        assert.equal(fixtureData().infoText, data.infoText)
    end)

    it("falls back to the pre-12.0 globals when C_GuildInfo has no reader", function()
        _G.C_GuildInfo.GetMOTD, _G.C_GuildInfo.GetInfoText = nil, nil
        _G.GetGuildRosterMOTD = function() return "Old MOTD" end
        _G.GetGuildInfoText = function() return "" end
        local data = exported(ns)
        assert.equal("Old MOTD", data.motd)
        assert.equal("", data.infoText)
    end)

    it("clips to 255 / 499 UTF-16 units without splitting a character", function()
        local s = WowStub.state
        s.guildMotd = string.rep("a", 300)
        s.guildInfoText = string.rep("b", 600)
        local data = exported(ns)
        assert.equal(string.rep("a", 255), data.motd)
        assert.equal(string.rep("b", 499), data.infoText)

        -- 2-byte characters: 255 units is 510 bytes, not 255.
        s.guildMotd = string.rep("\195\169", 300) -- é
        -- 3-byte characters, exactly at the cap: untouched.
        s.guildInfoText = string.rep("\226\130\172", 499) -- €
        data = exported(ns)
        assert.equal(string.rep("\195\169", 255), data.motd)
        assert.equal(string.rep("\226\130\172", 499), data.infoText)

        -- 4-byte characters are 2 units each: 127 fit in 255, 249 in 499.
        s.guildMotd = string.rep("\240\159\148\165", 200)
        s.guildInfoText = "x" .. string.rep("\240\159\148\165", 300)
        data = exported(ns)
        assert.equal(string.rep("\240\159\148\165", 127), data.motd)
        assert.equal(254, utf16Units(data.motd))
        assert.equal("x" .. string.rep("\240\159\148\165", 249), data.infoText)
        assert.equal(499, utf16Units(data.infoText))
    end)

    it("puts the keys on page 1 only of a paged roster", function()
        WowStub.state.guildRoster = WowStub.roster(600)
        local pages = pagesOf(ns)
        assert.equal(3, #pages)
        assert.equal(1, pages[1].page)
        assert.equal(fixtureData().motd, pages[1].payload.data.motd)
        assert.equal(fixtureData().infoText, pages[1].payload.data.infoText)
        for i = 2, 3 do
            assert.is_nil(pages[i].json:find('"motd"', 1, true))
            assert.is_nil(pages[i].json:find('"infoText"', 1, true))
        end
    end)

    it("never carries officer text", function()
        LedgerLinkDB.guildNotes = true
        local page = pagesOf(ns)[1]
        assert.is_nil(page.json:find("OFFICER SECRET", 1, true))
        assert.equal(false, page.payload.data.canViewOfficerNote)
    end)

    describe("from the roster cache (logout auto-export)", function()
        it("carries the boxes read while playing", function()
            ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
            local want = fixtureData()
            local payloads = logoutGuildPages(ns)
            assert.equal(want.motd, payloads[1].data.motd)
            assert.equal(want.infoText, payloads[1].data.infoText)
        end)

        it("carries them with /rl guildnotes on too", function()
            LedgerLinkDB.guildNotes = true
            ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
            local payloads = logoutGuildPages(ns)
            assert.equal(fixtureData().motd, payloads[1].data.motd)
            assert.equal(fixtureData().infoText, payloads[1].data.infoText)
        end)

        it("keeps \"\" for a box that was empty and omits one that could not be read", function()
            WowStub.state.guildMotd, WowStub.state.guildInfoText = "", nil
            ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
            local data = logoutGuildPages(ns)[1].data
            assert.equal("", data.motd)
            assert.is_nil(data.infoText)
        end)

        it("uses the text as of the last read before logout", function()
            ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
            WowStub.state.guildMotd = "Raid moved to Friday"
            ns.Guild.OnEvent("PLAYER_LEAVING_WORLD")
            assert.equal("Raid moved to Friday", logoutGuildPages(ns)[1].data.motd)
        end)

        it("puts the keys on page 1 only of a paged cached roster", function()
            WowStub.state.guildRoster = WowStub.roster(600)
            ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
            local payloads = logoutGuildPages(ns)
            assert.equal(3, #payloads)
            assert.equal(fixtureData().motd, payloads[1].data.motd)
            assert.equal(fixtureData().infoText, payloads[1].data.infoText)
            for i = 2, 3 do
                assert.is_nil(payloads[i].data.motd)
                assert.is_nil(payloads[i].data.infoText)
            end
        end)
    end)
end)

describe("ns.ClipUtf16", function()
    local ns = loadAddon()

    it("returns nil for anything that is not a string", function()
        assert.is_nil(ns.ClipUtf16(nil, 10))
        assert.is_nil(ns.ClipUtf16(42, 10))
    end)

    it("keeps a string at or under the cap, and clips by units over it", function()
        assert.equal("", ns.ClipUtf16("", 5))
        assert.equal("abc", ns.ClipUtf16("abc", 3))
        assert.equal("abc", ns.ClipUtf16("abcd", 3))
        assert.equal("a\195\169", ns.ClipUtf16("a\195\169\195\169", 2))
        -- A 2-unit character that would straddle the cap is dropped whole.
        assert.equal("ab", ns.ClipUtf16("ab\240\159\148\165cd", 3))
        assert.equal("ab\240\159\148\165", ns.ClipUtf16("ab\240\159\148\165cd", 4))
    end)

    it("never reads past a truncated character at the end", function()
        assert.equal("ab", ns.ClipUtf16("abc\240\159", 2))
        assert.equal("abc\240\159", ns.ClipUtf16("abc\240\159xx", 5))
    end)
end)
