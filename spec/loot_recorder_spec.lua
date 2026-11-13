-- Loot history recorder (Raid Ledger ROK-2184). The `loot` section is a v2
-- DRAFT: there is no contract/v2/schema.json yet, so these keys and limits are
-- the draft's §3 table, checked by hand. Replace them with a schema check
-- against the pinned contract/v2/ once Raid Ledger lands it.
local loadAddon = require("spec.support.load_addon")

local DATA_KEYS = { "drops", "minQuality", "windowEnd", "windowStart" }
local DROP_ALLOWED = { "at", "difficultyId", "encounterId", "encounterName", "instanceId", "itemId", "link",
    "looterGuid", "looterName", "method", "quality", "quantity" }
local DROP_REQUIRED = { "at", "itemId", "looterName", "method", "quantity" }

local function assertKeys(t, allowed, required, label)
    local set = {}
    for _, k in ipairs(allowed) do set[k] = true end
    for k in pairs(t) do assert(set[k], label .. " has unexpected key '" .. tostring(k) .. "'") end
    for _, k in ipairs(required) do assert(t[k] ~= nil, label .. " is missing '" .. k .. "'") end
end

local EPIC, RARE, UNCOMMON, COMMON = "a335ee", "0070dd", "1eff00", "ffffff"

local function link(id, colour, name)
    return "|cff" .. colour .. "|Hitem:" .. id .. "::::::::60:::::|h[" .. (name or ("Item " .. id)) .. "]|h|r"
end

local function loot(ns, text, name)
    ns.Loot.OnLoot(text, name or "", "", "", "", "", 0, 0, "", 0, 1, "")
end

local function kill(ns, encounterId, success)
    ns.Raid.OnEvent("ENCOUNTER_START", encounterId, "Boss " .. encounterId, 9, 40)
    WowStub.state.serverTime = WowStub.state.serverTime + 120
    ns.Raid.OnEvent("ENCOUNTER_END", encounterId, "Boss " .. encounterId, 9, 40, success == nil and 1 or success)
end

local function later(seconds) WowStub.state.serverTime = WowStub.state.serverTime + seconds end

describe("loot recorder (contract v2 draft)", function()
    local ns

    before_each(function()
        ns = loadAddon()
        WowStub.raid(25)
    end)

    it("records a group member's master-looted epic with the draft keys, their GUID and the boss", function()
        kill(ns, 663)
        later(30)
        loot(ns, "Raider3 Doe receives loot: " .. link(16921, EPIC, "Halo") .. ".", "Raider3 Doe")
        local data = ns.Loot.Build()
        assertKeys(data, DATA_KEYS, DATA_KEYS, "data")
        assert.equals(1, #data.drops)
        local d = data.drops[1]
        assertKeys(d, DROP_ALLOWED, DROP_REQUIRED, "drop")
        assert.equals(16921, d.itemId)
        assert.equals(1, d.quantity)
        assert.equals(4, d.quality)
        assert.equals("Raider3 Doe", d.looterName)
        assert.equals("Player-4395-00020003", d.looterGuid)
        assert.equals("master", d.method)
        assert.equals(409, d.instanceId)
        assert.equals(9, d.difficultyId)
        assert.equals(663, d.encounterId)
        assert.equals("Boss 663", d.encounterName)
        assert.equals(link(16921, EPIC, "Halo"), d.link)
        assert.equals(WowStub.state.serverTime, d.at)
        assert.equals(2, data.minQuality)
        assert.is_true(data.windowStart <= d.at and d.at <= data.windowEnd)
    end)

    it("records the exporter's own stack with its quantity and GUID", function()
        loot(ns, "You receive loot: " .. link(12345, UNCOMMON) .. "x3.", "Ana Forever")
        local d = ns.Loot.Build().drops[1]
        assert.equals(12345, d.itemId)
        assert.equals(3, d.quantity)
        assert.equals(2, d.quality)
        assert.equals("Ana Forever", d.looterName)
        assert.equals(WowStub.state.guid, d.looterGuid)
        assert.is_nil(d.encounterId)
        assert.is_nil(d.encounterName)
    end)

    it("leaves out the GUID of a looter who is not in the group", function()
        loot(ns, "Stranger Danger receives loot: " .. link(1, EPIC) .. ".")
        local d = ns.Loot.Build().drops[1]
        assert.equals("Stranger Danger", d.looterName)
        assert.is_nil(d.looterGuid)
    end)

    it("skips items below uncommon, lines outside a group or instance, money and unknown lines", function()
        loot(ns, "Raider3 Doe receives loot: " .. link(2, COMMON) .. ".")
        WowStub.state.instance = { "Elwynn Forest", "none", 0, "", 5, 0, false, 0 }
        loot(ns, "Raider3 Doe receives loot: " .. link(3, EPIC) .. ".")
        WowStub.state.instance = { "Molten Core", "raid", 9, "40 Player", 40, 0, false, 409 }
        WowStub.state.numGroupMembers = 0
        loot(ns, "Raider3 Doe receives loot: " .. link(4, EPIC) .. ".")
        WowStub.state.numGroupMembers = 25
        loot(ns, "Raider3 Doe receives loot: |cffffffff|Hcurrency:1:0|h[Coin]|h|r.")
        loot(ns, "Raider3 Doe creates: " .. link(5, EPIC) .. ".")
        assert.equals(0, #ns.Loot.Build().drops)
        local stats = ns.Loot.stats
        assert.equals(5, stats.seen)
        assert.equals(1, stats.lowQuality)
        assert.equals(2, stats.outside)
        assert.equals(1, stats.notItem)
        assert.equals(1, stats.unparsed)
        assert.equals(0, stats.recorded)
    end)

    it("never reads a secret line", function()
        local secretText = "Raider3 Doe receives loot: " .. link(6, EPIC) .. "."
        _G.issecretvalue = function(v) return v == secretText end
        loot(ns, secretText)
        assert.equals(0, #ns.Loot.Build().drops)
        assert.equals(1, ns.Loot.stats.secret)
    end)

    it("marks a won roll as `roll`; other group-loot drops by the threshold", function()
        WowStub.state.lootMethod = 3 -- Enum.LootMethod.Group
        loot(ns, "Raider4 Doe won: " .. link(7, EPIC) .. "")
        later(1)
        loot(ns, "Raider4 Doe receives loot: " .. link(7, EPIC) .. ".")
        loot(ns, "You won: " .. link(8, RARE))
        loot(ns, "You receive loot: " .. link(8, RARE) .. ".")
        loot(ns, "Raider5 Doe receives loot: " .. link(9, EPIC) .. ".") -- no won line seen
        WowStub.state.lootThreshold = 4
        loot(ns, "Raider6 Doe receives loot: " .. link(10, RARE) .. ".") -- below the threshold
        local methods = {}
        for _, d in ipairs(ns.Loot.Build().drops) do methods[d.itemId] = d.method end
        assert.same({ [7] = "roll", [8] = "roll", [9] = "unknown", [10] = "direct" }, methods)
    end)

    it("does not pair a won line with a receive line a minute later", function()
        WowStub.state.lootMethod = 3
        loot(ns, "Raider4 Doe won: " .. link(7, EPIC))
        later(ns.Loot.ROLL_MATCH_SECONDS + 1)
        loot(ns, "Raider4 Doe receives loot: " .. link(7, EPIC) .. ".")
        assert.equals("unknown", ns.Loot.Build().drops[1].method)
    end)

    it("reads free-for-all, round-robin and personal loot as `direct`", function()
        for value, itemId in pairs({ [0] = 11, [1] = 12, [5] = 13 }) do
            WowStub.state.lootMethod = value
            loot(ns, "Raider3 Doe receives loot: " .. link(itemId, EPIC) .. ".")
        end
        for _, d in ipairs(ns.Loot.Build().drops) do assert.equals("direct", d.method) end
    end)

    it("attributes a drop only to a kill in the same instance within 300 s", function()
        kill(ns, 663)
        later(ns.Loot.ATTRIBUTION_SECONDS + 1)
        loot(ns, "Raider3 Doe receives loot: " .. link(20, EPIC) .. ".")
        kill(ns, 664, 0) -- a wipe is never the source
        later(10)
        loot(ns, "Raider3 Doe receives loot: " .. link(21, EPIC) .. ".")
        kill(ns, 665)
        WowStub.state.instance = { "Onyxia's Lair", "raid", 9, "40 Player", 40, 0, false, 249 }
        later(10)
        loot(ns, "Raider3 Doe receives loot: " .. link(22, EPIC) .. ".")
        for _, d in ipairs(ns.Loot.Build().drops) do
            assert.is_nil(d.encounterId, "item " .. d.itemId)
            assert.is_nil(d.encounterName)
        end
    end)

    it("keeps 30 days: older drops go and the window starts 30 days back", function()
        loot(ns, "Raider3 Doe receives loot: " .. link(30, EPIC) .. ".")
        later(ns.Loot.WINDOW_SECONDS - 100)
        loot(ns, "Raider3 Doe receives loot: " .. link(31, EPIC) .. ".")
        later(200)
        local data = ns.Loot.Build()
        assert.equals(1, #data.drops)
        assert.equals(31, data.drops[1].itemId)
        assert.equals(WowStub.state.serverTime - ns.Loot.WINDOW_SECONDS, data.windowStart)
    end)

    it("starts the window when recording started, not 30 days back", function()
        local started = WowStub.state.serverTime
        ns.Loot.Drops() -- first use creates the store
        later(3600)
        local data = ns.Loot.Build()
        assert.equals(started, data.windowStart)
        assert.equals(WowStub.state.serverTime, data.windowEnd)
        assert.equals("[]", ns.Json.encode(data.drops))
    end)

    it("holds at most 500 drops, the newest, with the window moved to the oldest kept", function()
        for i = 1, ns.Loot.MAX_DROPS + 20 do
            later(1)
            loot(ns, "Raider3 Doe receives loot: " .. link(1000 + i, EPIC) .. ".")
        end
        local data = ns.Loot.Build()
        assert.equals(ns.Loot.MAX_DROPS, #ns.Loot.Drops())
        assert.equals(ns.Loot.MAX_DROPS, #data.drops)
        assert.equals(1021, data.drops[1].itemId)
        assert.equals(data.drops[1].at, data.windowStart)
        for i = 2, #data.drops do assert.is_true(data.drops[i - 1].at <= data.drops[i].at) end
    end)

    it("Newest cuts the oldest drops and moves the window start with them", function()
        for i = 1, 5 do
            later(10)
            loot(ns, "Raider3 Doe receives loot: " .. link(40 + i, EPIC) .. ".")
        end
        local cut = ns.Loot.Newest(ns.Loot.Build(), 2)
        assert.equals(2, #cut.drops)
        assert.equals(44, cut.drops[1].itemId)
        assert.equals(cut.drops[1].at, cut.windowStart)
    end)

    it("re-validates hand-edited SavedVariables into exactly the draft keys", function()
        local now = WowStub.state.serverTime
        ns.Loot.Drops()
        LedgerLinkDB.loot.since = now - 100
        LedgerLinkDB.loot.drops = {
            { at = now - 50, itemId = 1, quantity = 5000, looterName = "|cffffffffBob|r", method = "council",
                looterGuid = "Player-1-abcdef01", quality = 9, roll = 87, note = "x" },
            { at = now - 40, itemId = "2", quantity = 1, looterName = "Bob", method = "roll" },
            { at = now - 30, itemId = 3, looterName = "", method = "roll" },
            { at = now - 20, itemId = 4, looterName = "Bob", method = "direct", encounterName = "No id" },
            "junk",
        }
        local data = ns.Loot.Build()
        assert.equals(2, #data.drops)
        local d = data.drops[1]
        assertKeys(d, DROP_ALLOWED, DROP_REQUIRED, "drop")
        assert.equals(1000, d.quantity)
        assert.equals("Bob", d.looterName)
        assert.equals("unknown", d.method)
        assert.equals("Player-1-ABCDEF01", d.looterGuid)
        assert.is_nil(d.quality)
        assert.is_nil(data.drops[2].encounterName)
    end)

    it("matches positional GlobalStrings (languages that reorder the arguments)", function()
        _G.LOOT_ITEM_MULTIPLE = "Beute (%3$d): %2$s fuer %1$s."
        ns.Loot.ResetMatchers()
        local parsed = ns.Loot.Parse("Beute (4): " .. link(50, EPIC) .. " fuer Raider3 Doe.")
        assert.equals("Raider3 Doe", parsed.name)
        assert.equals(link(50, EPIC), parsed.link)
        assert.equals(4, parsed.quantity)
    end)

    it("maps positional arguments whose order is not its own inverse", function()
        _G.LOOT_ITEM_MULTIPLE = "%2$s (%3$d) -> %1$s."
        ns.Loot.ResetMatchers()
        loot(ns, link(50, EPIC) .. " (4) -> Raider3 Doe.")
        local d = ns.Loot.Build().drops[1]
        assert.equals(50, d.itemId)
        assert.equals(4, d.quantity)
        assert.equals("Raider3 Doe", d.looterName)
        assert.equals("Player-4395-00020003", d.looterGuid)
    end)

    it("never gives one realm's player another realm's GUID or roll win", function()
        WowStub.state.units.raid3.name = "Same-RealmA"
        assert.is_nil(ns.Loot.GuidFor("Same-RealmB"))
        assert.equals("Player-4395-00020003", ns.Loot.GuidFor("Same"))
        WowStub.state.units.raid4.name = "Same-RealmC"
        assert.is_nil(ns.Loot.GuidFor("Same")) -- two members fit: ambiguous
        WowStub.state.units.raid5.name = "Solo"
        assert.equals("Player-4395-00020005", ns.Loot.GuidFor("Solo-RealmX"))
        WowStub.state.lootMethod = 3
        loot(ns, "Same-RealmA won: " .. link(70, EPIC))
        loot(ns, "Same-RealmC receives loot: " .. link(70, EPIC) .. ".")
        loot(ns, "Same-RealmA receives loot: " .. link(70, EPIC) .. ".")
        local drops = ns.Loot.Build().drops
        assert.equals("unknown", drops[1].method)
        assert.equals("roll", drops[2].method)
    end)

    it("is not an export section yet: nothing can emit loot or a v2 string", function()
        loot(ns, "Raider3 Doe receives loot: " .. link(60, EPIC) .. ".")
        local pages, err = ns.Export.RunPages("loot")
        assert.is_nil(pages)
        assert.truthy(err:find("Unknown section", 1, true))
        assert.equals(1, ns.Export.ENVELOPE_VERSION)
        assert.equals(1, ns.Export.PAYLOAD_SCHEMA)
        local tokens = assert(ns.Export.RunAll())
        for _, token in ipairs(tokens) do assert.truthy(token:match("^!RL1!%a+[%-%dof]*!")) end
        assert.falsy(table.concat(tokens, "\n"):find("loot", 1, true))
    end)
end)

describe("/rl probe S10 (loot recorder checks)", function()
    local ns

    before_each(function()
        ns = loadAddon()
        WowStub.raid(25)
    end)

    local function report()
        ns.HandleSlash("probe")
        return ns.ExportFrame.GetText()
    end

    local function has(text, needle)
        assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
    end

    it("reports the strings, loot method, session counts and stored drops", function()
        kill(ns, 663)
        loot(ns, "Raider3 Doe receives loot: " .. link(16921, EPIC) .. ".", "Raider3 Doe")
        loot(ns, "Raider3 Doe creates: " .. link(5, EPIC) .. ".")
        local text = report()
        has(text, 'S10 loot strings: LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."')
        has(text, "S10 loot method: C_PartyInfo.GetLootMethod() = 2 (reads as master), GetLootMethod() = missing,"
            .. " GetLootThreshold() = 2, IsInGroup() = true, IsInInstance() = true, \"raid\", recording now = yes")
        has(text, "S10 C_LootHistory.GetAllEncounterInfos() = missing")
        has(text, "S10 loot lines this session: seen 2, recorded 1, outside a group/instance 0, below uncommon 0,"
            .. " secret 0, unparsed 1, not an item 0")
        has(text, "S10 last loot line: name argument empty, GUID argument empty, roster GUID -")
        has(text, "S10 last unparsed loot line: \"Raider3 Doe creates:")
        has(text, "S10 drops stored: 1 since ")
        has(text, "item 16921 quality 4 x1 master, instance 409, encounter 663, looter GUID yes")
    end)

    it("says when the event's arguments are secret, without keeping them", function()
        local secretName = "Raider3 Doe"
        _G.issecretvalue = function(v) return v == secretName end
        loot(ns, "Raider3 Doe receives loot: " .. link(1, EPIC) .. ".", secretName)
        has(report(), "S10 last loot line: name argument secret, GUID argument empty, roster GUID -")
        assert.is_nil(ns.Loot.last.looterGuid)
    end)
end)
