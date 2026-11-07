local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")
local seedPulls = require("spec.support.seed_pulls")

-- Contract AddonPullSchema keys (wow-addon-export.schema.ts); all strict.
local PULL_ALLOWED = { "difficultyId", "encounterId", "endAt", "groupSize", "instanceId", "name",
    "roster", "rosterNames", "startAt", "success" }
local PULL_REQUIRED = { "difficultyId", "encounterId", "endAt", "groupSize", "name",
    "roster", "rosterNames", "startAt", "success" }
local UNIX_SECONDS_MAX = 4102444800

local function assertKeys(t, allowed, required, label)
    local set = {}
    for _, k in ipairs(allowed) do set[k] = true end
    for k in pairs(t) do assert(set[k], label .. " has unexpected key '" .. tostring(k) .. "'") end
    for _, k in ipairs(required) do assert(t[k] ~= nil, label .. " is missing '" .. k .. "'") end
end

local function pull(ns, id, success, duration)
    ns.Raid.OnEvent("ENCOUNTER_START", id, "Boss " .. id, 9, 40)
    WowStub.state.serverTime = WowStub.state.serverTime + (duration or 120)
    ns.Raid.OnEvent("ENCOUNTER_END", id, "Boss " .. id, 9, 40, success)
end

local function exported(ns)
    local d = decode(assert(ns.Export.Run("raid")))
    assert.equals("raid", d.section)
    return d.payload.data.pulls, d
end

-- SavedVariables write plain tables: no metatables survive a /reload.
local function plainCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = plainCopy(x) end
    return out
end

describe("raid pull recorder", function()
    local ns

    before_each(function()
        ns = loadAddon()
        WowStub.raid(25)
    end)

    it("records a kill with exact contract keys, roster GUIDs and unix-second timestamps", function()
        pull(ns, 663, 1, 95)
        local pulls, d = exported(ns)
        assert.equals(1, #pulls)
        local p = pulls[1]
        assertKeys(p, PULL_ALLOWED, PULL_REQUIRED, "pull")
        assert.equals(663, p.encounterId)
        assert.equals("Boss 663", p.name)
        assert.equals(9, p.difficultyId)
        assert.equals(40, p.groupSize)
        assert.equals(409, p.instanceId)
        assert.is_true(p.success)
        assert.equals(1790000000, p.startAt)
        assert.equals(1790000095, p.endAt)
        assert(p.startAt < UNIX_SECONDS_MAX and p.endAt < UNIX_SECONDS_MAX, "timestamps must be unix seconds")
        assert.equals(25, #p.roster)
        assert.equals(#p.roster, #p.rosterNames)
        assert.equals("Player-4395-0ABCDEF0", p.roster[1])
        assert.equals("Ana Forever", p.rosterNames[1])
        assert.equals("Night Shift", d.payload.who.guildName)
    end)

    it("a wipe is success=false", function()
        pull(ns, 664, 0)
        assert.is_false(exported(ns)[1].success)
    end)

    it("the ring buffer keeps only the newest MAX_PULLS pulls", function()
        assert.equals(50, ns.Raid.MAX_PULLS)
        for i = 1, 60 do pull(ns, 1000 + i, 1, 10) end
        assert.equals(50, #ns.Raid.Pulls())
        assert.equals(50, #LedgerLinkDB.raid.pulls)
        local pulls = exported(ns)
        assert.equals(50, #pulls)
        assert.equals(1011, pulls[1].encounterId)
        assert.equals(1060, pulls[50].encounterId)
    end)

    it("caps the roster at 40 GUIDs and drops duplicates", function()
        WowStub.raid(40)
        WowStub.state.numGroupMembers = 45
        for i = 41, 45 do WowStub.state.units["raid" .. i] = { guid = "Player-4395-0000FFFF", name = "x" } end
        WowStub.state.units.raid2.guid = WowStub.state.units.raid3.guid
        pull(ns, 663, 1)
        local p = exported(ns)[1]
        assert.equals(39, #p.roster)
        assert.equals(39, #p.rosterNames)
        -- an over-full stored roster (old/hand-edited SavedVariables) is clipped on export
        local stored = LedgerLinkDB.raid.pulls[1]
        for i = 1, 50 do stored.roster[i] = string.format("Player-1-%08X", i); stored.rosterNames[i] = "n" .. i end
        assert.equals(40, #exported(ns)[1].roster)
    end)

    it("a millisecond server clock is stored as unix seconds", function()
        WowStub.state.serverTime = 1790000000123
        ns.Raid.OnEvent("ENCOUNTER_START", 663, "Lucifron", 9, 40)
        ns.Raid.OnEvent("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
        local p = exported(ns)[1]
        assert.equals(1790000000, p.startAt)
        assert.equals(1790000000, p.endAt)
    end)

    it("exports correctly after a SavedVariables round trip (no metatables)", function()
        pull(ns, 663, 1)
        local saved = plainCopy(LedgerLinkDB)
        ns = loadAddon()
        _G.LedgerLinkDB = saved
        local pulls, d = exported(ns)
        assert.equals(1, #pulls)
        assert.truthy(d.json:find('"roster":%["Player'))
    end)

    it("END without START (reload mid-pull) still records the pull", function()
        ns.Raid.OnEvent("ENCOUNTER_END", 665, "Gehennas", 9, 40, 1)
        local p = exported(ns)[1]
        assert.equals(665, p.encounterId)
        assert.equals(p.startAt, p.endAt)
        assert.equals(25, #p.roster)
    end)

    it("secret unit values at START are re-read at END", function()
        for _, u in pairs(WowStub.state.units) do u.secret = true end
        ns.Raid.OnEvent("ENCOUNTER_START", 663, "Lucifron", 9, 40)
        assert.equals(0, #LedgerLinkDB.raid.current.roster)
        for _, u in pairs(WowStub.state.units) do u.secret = nil end
        ns.Raid.OnEvent("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
        assert.equals(25, #exported(ns)[1].roster)
    end)

    it("a 5-player party uses player + party1-4", function()
        local s = WowStub.state
        s.inRaid, s.numGroupMembers, s.units = false, 3, {
            party1 = { guid = "Player-4395-00000001", name = "One A" },
            party2 = { guid = "Player-4395-00000002", name = "Two B" },
        }
        pull(ns, 2001, 1)
        local p = exported(ns)[1]
        assert.same({ "Player-4395-0ABCDEF0", "Player-4395-00000001", "Player-4395-00000002" }, p.roster)
    end)

    it("/rl raid clear forgets recorded pulls", function()
        pull(ns, 663, 1)
        SlashCmdList.LEDGERLINK("raid clear")
        assert.equals(0, #ns.Raid.Pulls())
        local none, err = ns.Export.Run("raid")
        assert.is_nil(none)
        assert.truthy(err:find("No boss pulls"))
    end)

    it("/rl export raid shows one unpaged !RL1!raid! string", function()
        pull(ns, 663, 1)
        SlashCmdList.LEDGERLINK("export raid")
        assert.truthy(ns.ExportFrame.GetText():match("^!RL1!raid![A-Za-z0-9+/]+=*$"))
        assert.same({ 1, 1 }, { ns.ExportFrame.GetPage() })
        assert.equals("", ns.ExportFrame.GetPageLabel())
    end)
end)

-- Raid Ledger ROK-2123: a long pull history must never make the raid export
-- too large for Raid Ledger (pulls <= 200, paste <= 256 KiB); when something
-- has to go, the oldest pulls go first.
describe("raid pull history size", function()
    local ns

    before_each(function()
        ns = loadAddon()
        WowStub.raid(40)
    end)

    local function encounterIds(pulls)
        local ids = {}
        for i, p in ipairs(pulls) do ids[i] = p.encounterId end
        return ids
    end

    it("an account with 250 stored pulls exports the newest 50, oldest first, under 256 KiB", function()
        LedgerLinkDB.raid = { pulls = seedPulls(250) }
        local text = assert(ns.Export.Run("raid"))
        assert(#text <= 262144, "raid paste is " .. #text .. " bytes")
        local pulls = decode(text).payload.data.pulls
        assert.equals(50, #pulls)
        assert.equals(1201, pulls[1].encounterId)
        assert.equals(1250, pulls[50].encounterId)
        assert.equals(40, #pulls[50].roster)
        -- and the SavedVariables stop growing: the oldest 200 are gone
        assert.equals(50, #LedgerLinkDB.raid.pulls)
        assert.equals(1201, LedgerLinkDB.raid.pulls[1].encounterId)
    end)

    it("never exports more than the contract's 200 pulls, even from a bigger buffer", function()
        ns.Raid.MAX_PULLS = 300
        LedgerLinkDB.raid = { pulls = seedPulls(300) }
        local text = assert(ns.Export.Run("raid"))
        assert(#text <= 262144, "raid paste is " .. #text .. " bytes")
        local pulls = decode(text).payload.data.pulls
        assert.equals(200, #pulls)
        assert.equals(1101, pulls[1].encounterId)
        assert.equals(1300, pulls[200].encounterId)
    end)

    it("a raid string over its budget keeps the newest pulls that fit, and says so", function()
        LedgerLinkDB.raid = { pulls = seedPulls(50) }
        local full = assert(ns.Export.Run("raid"))
        local budget = math.floor(#full / 3)
        local pages, note = ns.Export.RunPages("raid", budget)
        assert.equals(1, #assert(pages))
        assert(#pages[1] <= budget, #pages[1] .. " bytes over a " .. budget .. " byte budget")
        local pulls = decode(pages[1]).payload.data.pulls
        assert(#pulls > 1 and #pulls < 50, "kept " .. #pulls .. " pulls")
        assert.equals(1050, pulls[#pulls].encounterId) -- the newest pull is always in
        local ids = encounterIds(pulls)
        for i = 2, #ids do assert.equals(ids[i - 1] + 1, ids[i]) end -- a contiguous newest run
        assert.equals(string.format("The raid export holds the newest %d of 50 pulls, to fit Raid Ledger's size limit.",
            #pulls), note)
        -- one more pull would not have fitted
        LedgerLinkDB.raid = { pulls = seedPulls(50) }
        local raid = ns.Raid.Build()
        local payload = ns.Export.BuildPayload("raid", ns.Raid.Newest(raid, #pulls + 1))
        assert(#ns.Export.Encode("raid", payload) > budget)
    end)

    it("the per-string limit trims a standalone raid export too", function()
        LedgerLinkDB.raid = { pulls = seedPulls(50) }
        ns.Export.MAX_STRING_BYTES = 16 * 1024
        SlashCmdList.LEDGERLINK("export raid")
        local text = ns.ExportFrame.GetText()
        assert(#text <= 16 * 1024)
        local pulls = decode(text).payload.data.pulls
        assert.equals(1050, pulls[#pulls].encounterId)
        assert.truthy(WowStub.printed[#WowStub.printed]:find("holds the newest %d+ of 50 pulls"))
    end)

    it("fails with the size message when not even one pull fits", function()
        LedgerLinkDB.raid = { pulls = seedPulls(3) }
        local pages, err, tooLarge = ns.Export.RunPages("raid", 200)
        assert.is_nil(pages)
        assert.truthy(err:find("too large"))
        assert.is_true(tooLarge)
    end)

    it("Export all gives the raid what is left of the one paste instead of failing", function()
        LedgerLinkDB.raid = { pulls = seedPulls(50) }
        local untrimmed = assert(ns.Export.RunAll())
        local raidBytes = #untrimmed[#untrimmed]
        -- a paste limit that fits everything but about half the raid string
        ns.Export.MAX_PASTE_BYTES = #table.concat(untrimmed, "\n") - math.floor(raidBytes / 2)
        local tokens, notes = assert(ns.Export.RunAll())
        local text = table.concat(tokens, "\n")
        assert(#text <= ns.Export.MAX_PASTE_BYTES)
        local pulls = decode(tokens[#tokens]).payload.data.pulls
        assert(#pulls < 50 and #pulls > 1, "kept " .. #pulls .. " pulls")
        assert.equals(1050, pulls[#pulls].encounterId)
        assert.truthy(notes[#notes]:find("holds the newest %d+ of 50 pulls"))
        -- and the logout auto-export stores it, raid included
        assert.is_true(ns.Outbox.OnLogout())
        local _, entry = next(LedgerLinkDB.outbox)
        assert.equals("all", entry.section)
        assert.truthy(entry.text:find("!RL1!raid!", 1, true))
    end)

    it("Export all with no room left for a single pull keeps the one-paste message", function()
        LedgerLinkDB.raid = { pulls = seedPulls(5) }
        local tokens = assert(ns.Export.RunAll())
        ns.Export.MAX_PASTE_BYTES = #table.concat(tokens, "\n", 1, #tokens - 1) + 10
        local none, err = ns.Export.RunAll()
        assert.is_nil(none)
        assert.truthy(err:find("too big for one paste"))
    end)
end)
