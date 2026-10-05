local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")

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
