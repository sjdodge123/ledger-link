local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")

-- Key sets copied from the Raid Ledger contract (wow-addon-export.schema.ts).
local GUILD_ALLOWED = { "canViewOfficerNote", "members", "name", "rawRealm", "snapshotAt" }
local GUILD_REQUIRED = { "canViewOfficerNote", "members", "name", "snapshotAt" }
local MEMBER_ALLOWED = { "class", "guid", "lastOnlineDays", "level", "name", "note", "online", "rank", "rankIndex" }
local MEMBER_REQUIRED = { "class", "guid", "level", "name", "online", "rank", "rankIndex" }

local function assertKeys(t, allowed, required, label)
    local set = {}
    for _, k in ipairs(allowed) do set[k] = true end
    for k in pairs(t) do assert(set[k], label .. " has unexpected key '" .. tostring(k) .. "'") end
    for _, k in ipairs(required) do assert(t[k] ~= nil, label .. " is missing '" .. k .. "'") end
end

local function pagesOf(ns)
    local pages = assert(ns.Export.RunPages("guild"))
    local decoded = {}
    for i, p in ipairs(pages) do decoded[i] = decode(p) end
    return pages, decoded
end

-- Server-side reassembly (addon-import.pages.ts): sort by the header's page
-- number, then concatenate members.
local function reassemble(decoded)
    local sorted = {}
    for i, d in ipairs(decoded) do sorted[i] = d end
    table.sort(sorted, function(a, b) return (a.page or 0) < (b.page or 0) end)
    local guids = {}
    for _, d in ipairs(sorted) do
        for _, m in ipairs(d.payload.data.members) do guids[#guids + 1] = m.guid end
    end
    return guids
end

describe("guild export", function()
    local ns

    before_each(function() ns = loadAddon() end)

    it("a small guild is one unpaged !RL1!guild! string with exact contract keys", function()
        local pages, decoded = pagesOf(ns)
        assert.equals(1, #pages)
        assert.truthy(pages[1]:match("^!RL1!guild![A-Za-z0-9+/]+=*$"))
        local data = decoded[1].payload.data
        assertKeys(data, GUILD_ALLOWED, GUILD_REQUIRED, "guild data")
        assert.equals("Night Shift", data.name)
        assert.equals(false, data.canViewOfficerNote)
        assert.equals(1790000000, data.snapshotAt)
        assert.equals(3, #data.members)
        for i, m in ipairs(data.members) do
            assertKeys(m, MEMBER_ALLOWED, MEMBER_REQUIRED, "member " .. i)
            assert.truthy(m.guid:match("^Player%-%d+%-%x+$"))
        end
        assert.equals("Player-4395-0ABCDEF0", data.members[1].guid)
        assert.is_true(data.members[1].online)
        assert.is_nil(data.members[1].lastOnlineDays)
        assert.equals(2, data.members[2].lastOnlineDays)
    end)

    it("never emits officerNote, even though the roster API returns one", function()
        LedgerLinkDB.guildNotes = true -- public notes on: the closest a bug could get
        local pages, decoded = pagesOf(ns)
        for _, d in ipairs(decoded) do
            assert(not d.json:find("officerNote", 1, true), "officerNote key leaked into the guild export")
            assert(not d.json:find("OFFICER SECRET", 1, true), "officer note text leaked into the guild export")
            assert(d.payload.data.canViewOfficerNote == false, "canViewOfficerNote must always be false")
            for _, m in ipairs(d.payload.data.members) do
                assert(m.officerNote == nil, "member row carries officerNote")
            end
        end
        assert.equals(1, #pages)
    end)

    it("public notes only when /rl guildnotes on", function()
        local _, off = pagesOf(ns)
        assert.is_nil(off[1].payload.data.members[2].note)
        SlashCmdList.LEDGERLINK("guildnotes on")
        local _, on = pagesOf(ns)
        assert.equals("public note 1", on[1].payload.data.members[2].note)
    end)

    it("splits 600 members into 3 pages that share one envelope and reassemble in any order", function()
        WowStub.state.guildRoster = WowStub.roster(600)
        local pages, decoded = pagesOf(ns)
        assert(#pages == 3, "expected 3 pages for 600 members, got " .. #pages)
        local first = decoded[1].payload
        for i, d in ipairs(decoded) do
            assert.truthy(pages[i]:match("^!RL1!guild%-" .. i .. "of3!"))
            assert(#d.payload.data.members <= ns.Guild.MEMBERS_PER_PAGE,
                "page " .. i .. " has " .. #d.payload.data.members .. " members, over the page size")
            assert.equals(first.exportedAt, d.payload.exportedAt)
            assert.equals(first.who.guid, d.payload.who.guid)
            assert.equals(first.data.snapshotAt, d.payload.data.snapshotAt)
            assert.equals(first.data.name, d.payload.data.name)
            assertKeys(d.payload.data, GUILD_ALLOWED, GUILD_REQUIRED, "page " .. i)
        end
        local inOrder = reassemble(decoded)
        local shuffled = reassemble({ decoded[3], decoded[1], decoded[2] })
        assert.same(inOrder, shuffled)
        -- ...and equals the roster exported as a single page.
        ns.Guild.MEMBERS_PER_PAGE = 2000
        local _, single = pagesOf(ns)
        assert.same(reassemble(single), inOrder)
        assert.equals(600, #inOrder)
    end)

    it("/rl export guild shows pages with Prev/Next and the paste-all hint", function()
        WowStub.state.guildRoster = WowStub.roster(600)
        SlashCmdList.LEDGERLINK("export guild")
        assert.same({ 1, 3 }, { ns.ExportFrame.GetPage() })
        assert.equals("Page 1/3", ns.ExportFrame.GetPageLabel())
        assert.truthy(ns.ExportFrame.GetText():match("^!RL1!guild%-1of3!"))
        assert.truthy(ns.ExportFrame.PAGE_HINT:find("one box"))
        ns.ExportFrame.PrevPage()
        assert.equals(1, (ns.ExportFrame.GetPage()))
        ns.ExportFrame.NextPage()
        ns.ExportFrame.NextPage()
        ns.ExportFrame.NextPage()
        assert.equals("Page 3/3", ns.ExportFrame.GetPageLabel())
        assert.truthy(ns.ExportFrame.GetText():match("^!RL1!guild%-3of3!"))
        assert.equals(3, LedgerLinkDB.lastExport.guild.pages)
        -- Export.Run is the whole paste: pages joined by newlines.
        local paste = assert(ns.Export.Run("guild"))
        assert.equals(3, select(2, paste:gsub("!RL1!guild%-", "")))
    end)

    it("2000 members fit in exactly 8 pages; more pages than the server takes is refused", function()
        WowStub.state.guildRoster = WowStub.roster(2000)
        local pages = assert(ns.Export.RunPages("guild"))
        assert.equals(8, #pages)
        ns.Guild.MEMBERS_PER_PAGE = 100
        local none, err = ns.Export.RunPages("guild")
        assert.is_nil(none)
        assert.truthy(err:find("at most 8"))
    end)

    it("over 2000 members: keeps the exporter + online/recent members, caps at 2000, warns", function()
        local rows = WowStub.roster(2100)
        -- move the exporter to the end so the cap has to pull them forward
        table.insert(rows, table.remove(rows, 1))
        WowStub.state.guildRoster = rows
        WowStub.state.lastOnline[2050] = { 1, 0, 0, 0 } -- a year offline
        local pages, decoded = pagesOf(ns)
        assert.equals(8, #pages)
        local guids = reassemble(decoded)
        assert.equals(2000, #guids)
        local present = {}
        for _, g in ipairs(guids) do present[g] = true end
        assert.is_true(present["Player-4395-0ABCDEF0"])
        assert.is_nil(present[string.format("Player-4395-%08X", 0x10000 + 2049)])
        local warned = false
        for _, line in ipairs(WowStub.printed) do warned = warned or line:find("100 long%-offline") ~= nil end
        assert.is_true(warned)
    end)

    it("drops duplicate GUIDs and unreadable rows instead of failing the server merge", function()
        local s = WowStub.state
        s.guildRoster[4] = WowStub.member(1, { name = "dupe" })
        s.guildRoster[5] = WowStub.member(9, { guid = "Player-4395-xyz" })
        s.guildRoster[6] = WowStub.member(10, { class = "Mage" })
        s.guildRoster[7] = WowStub.member(11, { level = 0 })
        local _, decoded = pagesOf(ns)
        local guids = reassemble(decoded)
        assert.equals(3, #guids)
        local seen = {}
        for _, g in ipairs(guids) do
            assert(not seen[g], "duplicate guid " .. g)
            seen[g] = true
        end
        local text = table.concat(WowStub.printed, "\n")
        assert.truthy(text:find("1 duplicate roster row"))
        assert.truthy(text:find("3 roster row%(s%) were unreadable"))
    end)

    -- Beta 2026-10-05: /rl export guild raised "LedgerLink has been blocked
    -- from an action only available to the Blizzard UI" (and every button on
    -- that popup crashed the client). By elimination (probe + char export used
    -- the same window and roster reads without it) the trigger is the roster
    -- request, so the addon never requests the roster itself.
    it("never asks the server for the roster (C_GuildInfo.GuildRoster / GuildRoster)", function()
        _G.GuildRoster = function() WowStub.state.rosterRequests = WowStub.state.rosterRequests + 1 end
        SlashCmdList.LEDGERLINK("export guild")
        WowStub.state.guildRoster = {}
        SlashCmdList.LEDGERLINK("export guild")
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        _G.GuildRoster = nil
        assert.equals(0, WowStub.state.rosterRequests)
    end)

    it("asks the player to open the Guild window when the roster is not loaded, then exports", function()
        local rows = WowStub.state.guildRoster
        WowStub.state.guildRoster = {}
        SlashCmdList.LEDGERLINK("export guild")
        assert.truthy(WowStub.printed[#WowStub.printed]:find("open the Guild window", 1, true))
        assert.is_nil(LedgerLinkDB.lastExport.guild)
        WowStub.state.guildRoster = rows -- opening the Guild window loads it
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        assert.truthy(ns.ExportFrame.GetText():match("^!RL1!guild!"))
        local shownAt = #WowStub.printed
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE") -- a later update does not re-open it
        assert.equals(shownAt, #WowStub.printed)
    end)

    it("refuses when not in a guild", function()
        WowStub.state.guild = nil
        local pages, err = ns.Export.RunPages("guild")
        assert.is_nil(pages)
        assert.truthy(err:find("not in a guild"))
    end)

    it("rawRealm comes from GetGuildInfo's realm, else GetRealmName", function()
        local _, a = pagesOf(ns)
        assert.equals("Forever", a[1].payload.data.rawRealm)
        WowStub.state.guildRealm = "Shard-7"
        local _, b = pagesOf(ns)
        assert.equals("Shard-7", b[1].payload.data.rawRealm)
    end)
end)
