-- Raid Ledger replaces the whole char snapshot on import (ROK-2125 notes in
-- its addon-import-char.quests-carry.ts), so an empty list read before the
-- data loaded, during an outage (2026-11-13) or at logout would wipe what it
-- stored: `quests.completed: []` means "has completed no quests", and
-- `lockouts: []` / `quests.inProgress: []` replace the stored ones. The addon
-- keeps the last good read this session and trusts an empty read only once
-- the game has sent that data (QUEST_LOG_UPDATE / UPDATE_INSTANCE_INFO) and
-- while in the world. No wire-format change.
local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")
local importString = require("spec.support.import")

local GUID = "Player-4395-0ABCDEF0"
local MC = { "Molten Core", 1, 3600, 9, true, false, 0, true, 40, "40 Player", 10, 3, false, 409 }

local function charData(ns)
    return decode(assert(ns.Export.RunPages("char"))[1])
end

local function logoutChar(ns)
    ns.Outbox.frame:GetScript("OnEvent")(ns.Outbox.frame, "PLAYER_LOGOUT")
    for _, group in ipairs(importString(LedgerLinkDB.outbox[GUID].text).groups) do
        if group.section == "char" then return group.payloads[1].data end
    end
    error("the logout export has no char section")
end

describe("char export: blank reads never replace data read earlier", function()
    local ns, completed, log
    before_each(function()
        ns = loadAddon()
        completed = { 457, 6, 456 }
        log = { { questID = 7, title = "Kobold Camp Cleanup" } }
        _G.C_QuestLog = {
            GetAllCompletedQuestIDs = function() return completed end,
            GetNumQuestLogEntries = function() return #log end,
            GetInfo = function(i) return log[i] end,
            GetQuestObjectives = function() return {} end,
        }
    end)
    after_each(function()
        _G.C_QuestLog = nil
        ns.Char.OMIT_UNKNOWN_COMPLETED = false
    end)

    it("registers QUEST_LOG_UPDATE and UPDATE_INSTANCE_INFO", function()
        assert.is_true(ns.Char.frame.events.QUEST_LOG_UPDATE)
        assert.is_true(ns.Char.frame.events.UPDATE_INSTANCE_INFO)
    end)

    describe("completed quests", function()
        it("keeps the last non-empty list when a later read is empty (outage / logout)", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            completed = {}
            assert.same({ 6, 456, 457 }, charData(ns).payload.data.quests.completed)
            assert.same({ 6, 456, 457 }, logoutChar(ns).quests.completed)
        end)

        it("takes a newer non-empty list", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            completed = { 6, 456, 457, 900 }
            assert.same({ 6, 456, 457, 900 }, charData(ns).payload.data.quests.completed)
        end)

        it("with nothing read this session: sends [] (pre-ROK-2125 servers need the key)", function()
            completed = {}
            local d = charData(ns)
            assert.same({}, d.payload.data.quests.completed)
            assert.truthy(d.json:find('"completed":[]', 1, true))
        end)

        it("with nothing read this session and OMIT_UNKNOWN_COMPLETED: leaves `completed` out", function()
            ns.Char.OMIT_UNKNOWN_COMPLETED = true
            completed = {}
            local d = charData(ns)
            assert.is_nil(d.json:find('"completed"', 1, true))
            assert.is_table(d.payload.data.quests.inProgress) -- `quests` stays, so the server carries its list
        end)

        it("never throttles away the first non-empty read", function()
            completed = {}
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD") -- empty: nothing cached
            completed = { 6, 456, 457 }
            ns.Char.OnEvent("QUEST_LOG_UPDATE") -- same second: still scanned
            completed = {}
            ns.Char.OnEvent("PLAYER_LEAVING_WORLD")
            assert.same({ 6, 456, 457 }, logoutChar(ns).quests.completed)
        end)

        it("keeps the truncation flag with the cached list", function()
            ns.Char.QUESTS_COMPLETED_MAX = 2
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            completed = {}
            local q = charData(ns).payload.data.quests
            assert.same({ 6, 456 }, q.completed)
            assert.is_true(q.completedTruncated)
        end)
    end)

    describe("quest log", function()
        it("keeps the cached log when an empty read comes before QUEST_LOG_UPDATE", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            log = {}
            assert.equal(7, charData(ns).payload.data.quests.inProgress[1].questId)
        end)

        it("sends an empty log once QUEST_LOG_UPDATE arrived (every quest turned in)", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            log = {}
            ns.Char.OnEvent("QUEST_LOG_UPDATE")
            local d = charData(ns)
            assert.same({}, d.payload.data.quests.inProgress)
        end)

        it("re-reads the log on every QUEST_LOG_UPDATE, even inside the scan throttle", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            ns.Char.OnEvent("QUEST_LOG_UPDATE") -- completed scan + log
            log = {} -- the last quest turned in a second later
            WowStub.state.serverTime = WowStub.state.serverTime + 1
            ns.Char.OnEvent("QUEST_LOG_UPDATE") -- throttled scan, log still read
            assert.same({}, ns.Char.cache.inProgress)
            ns.Char.OnEvent("PLAYER_LEAVING_WORLD")
            assert.same({}, logoutChar(ns).quests.inProgress)
        end)

        it("never trusts an empty log read while leaving the world", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            ns.Char.OnEvent("QUEST_LOG_UPDATE")
            log = {}
            ns.Char.OnEvent("PLAYER_LEAVING_WORLD")
            assert.equal(7, logoutChar(ns).quests.inProgress[1].questId)
        end)
    end)

    describe("lockouts", function()
        it("keeps the cached lockouts when an empty read comes before UPDATE_INSTANCE_INFO", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            WowStub.state.lockouts = {}
            local lockouts = charData(ns).payload.data.lockouts
            assert.equal(1, #lockouts)
            assert.equal(409, lockouts[1].instanceId)
        end)

        it("sends [] once UPDATE_INSTANCE_INFO arrived and the list really is empty", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            WowStub.state.lockouts = {}
            ns.Char.OnEvent("UPDATE_INSTANCE_INFO")
            local d = charData(ns)
            assert.truthy(d.json:find('"lockouts":[]', 1, true))
        end)

        it("keeps them at logout even after UPDATE_INSTANCE_INFO (the client empties them)", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            ns.Char.OnEvent("UPDATE_INSTANCE_INFO")
            ns.Char.OnEvent("PLAYER_LEAVING_WORLD")
            WowStub.state.lockouts = {}
            assert.equal(1, #logoutChar(ns).lockouts)
        end)

        it("drops cached lockouts that have reset since", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            WowStub.state.lockouts = {}
            WowStub.state.serverTime = WowStub.state.serverTime + 3600
            assert.same({}, charData(ns).payload.data.lockouts)
        end)

        it("takes a new non-empty read over the cache", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            local other = { unpack(MC) }
            other[1], other[14] = "Onyxia's Lair", 249
            WowStub.state.lockouts = { other }
            local lockouts = charData(ns).payload.data.lockouts
            assert.equal(1, #lockouts)
            assert.equal(249, lockouts[1].instanceId)
        end)

        it("needs a fresh UPDATE_INSTANCE_INFO after a loading screen", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            ns.Char.OnEvent("UPDATE_INSTANCE_INFO")
            ns.Char.OnEvent("PLAYER_LEAVING_WORLD")
            WowStub.state.lockouts = {} -- still empty right after the loading screen
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            assert.equal(1, #charData(ns).payload.data.lockouts)
            ns.Char.OnEvent("UPDATE_INSTANCE_INFO")
            assert.same({}, charData(ns).payload.data.lockouts)
        end)

        it("ignores UPDATE_INSTANCE_INFO while leaving the world", function()
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            ns.Char.OnEvent("PLAYER_LEAVING_WORLD")
            WowStub.state.lockouts = {}
            ns.Char.OnEvent("UPDATE_INSTANCE_INFO")
            assert.is_false(ns.Char.loaded.instanceInfo)
            assert.equal(1, #logoutChar(ns).lockouts)
        end)
    end)

    it("says in /rl probe what is cached and whether the data loaded", function()
        assert.equal("char cache: completed quests = none; quest log = none (QUEST_LOG_UPDATE no); "
            .. "lockouts = none (UPDATE_INSTANCE_INFO no); unknown completed = sent as []", ns.Probe.CharCacheLine())
        ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
        ns.Char.OnEvent("UPDATE_INSTANCE_INFO")
        local line = ns.Probe.CharCacheLine()
        assert.equal("char cache: completed quests = 3 ids; quest log = 1 quests (QUEST_LOG_UPDATE no); "
            .. "lockouts = 1 lockouts (UPDATE_INSTANCE_INFO yes); unknown completed = sent as []", line)
        assert.truthy(ns.Probe.Report():find(line, 1, true))
    end)
end)
