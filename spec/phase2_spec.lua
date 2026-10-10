-- Phase 2 (Raid Ledger ROK-1742, contract 3b4418ff): who.gender, every talent
-- node with positions + tree/row/col hints + name/spellId/maxRanks, and the
-- quests block (completed ascending, capped at 10 000 with completedTruncated;
-- inProgress <= 35 with objectives <= 10).
local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")

local function payload(ns, section)
    return decode(assert(ns.Export.RunPages(section or "char"))[1]).payload
end

local function printed(text)
    for _, line in ipairs(WowStub.printed) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

describe("Phase 2 fields", function()
    local ns, saved
    local GLOBALS = { "UnitSex", "C_QuestLog", "C_Spell" }
    before_each(function()
        ns = loadAddon()
        saved = {}
        for _, g in ipairs(GLOBALS) do saved[g] = rawget(_G, g) end
    end)
    after_each(function()
        for _, g in ipairs(GLOBALS) do _G[g] = saved[g] end
        C_Traits.GetEntryInfo, C_Traits.GetDefinitionInfo = nil, nil
    end)

    describe("who.gender", function()
        it("maps UnitSex 2 / 3 to male / female in every section", function()
            _G.UnitSex = function() return 2 end
            assert.equal("male", payload(ns).who.gender)
            _G.UnitSex = function() return 3 end
            assert.equal("female", payload(ns).who.gender)
            assert.equal("female", payload(ns, "guild").who.gender)
        end)

        it("is left out when UnitSex is unknown, missing or errors", function()
            _G.UnitSex = function() return 1 end
            assert.is_nil(payload(ns).who.gender)
            _G.UnitSex = nil
            assert.is_nil(payload(ns).who.gender)
            _G.UnitSex = function() error("nope") end
            assert.is_nil(payload(ns).who.gender)
        end)
    end)

    describe("talent nodes", function()
        before_each(function()
            local n = WowStub.state.talentNodes
            n[101].posX, n[101].posY, n[101].maxRanks, n[101].entryIDs = 1020, 2130, 3, { 9001 }
            n[102].posX, n[102].posY, n[102].maxRanks, n[102].entryIDs = 5030, 2735.4, 1, { 9002 }
            n[103].entryIDs = { 9003, 9004 } -- choice node, no active entry, no position
            C_Traits.GetEntryInfo = function(_, e) return { definitionID = e - 4000 } end
            C_Traits.GetDefinitionInfo = function(d) return { spellID = d + 7000 } end
            _G.C_Spell = { GetSpellName = function(id) return "Spell " .. id end }
        end)

        it("sends every node with positions, grid hints, name, spellId and maxRanks", function()
            local nodes = payload(ns).data.talents.nodes
            assert.same({ nodeId = 101, rank = 2, entryId = 9001, name = "Spell 12001", spellId = 12001, maxRanks = 3,
                posX = 1020, posY = 2130, tree = 0, row = 0, col = 0 }, nodes[1])
            assert.same({ nodeId = 102, rank = 0, entryId = 9002, name = "Spell 12002", spellId = 12002, maxRanks = 1,
                posX = 5030, posY = 2735, tree = 1, row = 1, col = 0 }, nodes[2])
        end)

        it("leaves out entry, name and spell for an unchosen choice node, and positions it lacks", function()
            assert.same({ nodeId = 103, rank = 1 }, payload(ns).data.talents.nodes[3])
        end)

        it("drops a grid hint outside the contract range but keeps the raw position", function()
            WowStub.state.talentNodes[102].posY = 2130 + 600 * 12 -- row 12 > 9
            local node = payload(ns).data.talents.nodes[2]
            assert.equal(9330, node.posY)
            assert.is_nil(node.row)
            assert.is_nil(node.tree)
            assert.is_nil(node.col)
        end)

        it("clips a long name to 64 bytes without splitting a UTF-8 character", function()
            _G.C_Spell = { GetSpellName = function() return string.rep("é", 40) end } -- 80 bytes
            local name = payload(ns).data.talents.nodes[1].name
            assert.is_true(#name <= 64)
            assert.equal(string.rep("é", 32), name)
        end)
    end)

    describe("quests", function()
        local completed
        before_each(function()
            completed = { 457, 6, 456 }
            _G.C_QuestLog = {
                GetAllCompletedQuestIDs = function() return completed end,
                GetNumQuestLogEntries = function() return 3, 2 end,
                GetInfo = function(i)
                    return ({ { title = "Elwynn Forest", isHeader = true },
                        { questID = 7, title = "Kobold Camp Cleanup" },
                        { questID = 98391, title = "The Sisterhood of Elune" } })[i]
                end,
                GetQuestObjectives = function(id)
                    if id == 7 then
                        return { { text = "4/10 Kobold Vermin slain", finished = false, numFulfilled = 4, numRequired = 10 } }
                    end
                    return {}
                end,
            }
        end)

        it("sends completed ids ascending and the quest log with objectives", function()
            local q = payload(ns).data.quests
            assert.same({ 6, 456, 457 }, q.completed)
            assert.is_nil(q.completedTruncated)
            assert.same({ { questId = 7, title = "Kobold Camp Cleanup",
                objectives = { { text = "4/10 Kobold Vermin slain", done = false, have = 4, need = 10 } } },
                { questId = 98391, title = "The Sisterhood of Elune" } }, q.inProgress)
        end)

        it("caps completed at 10 000 (lowest ids first), sets completedTruncated and says so", function()
            completed = {}
            for i = 10002, 1, -1 do completed[#completed + 1] = i end
            local q = payload(ns).data.quests
            assert.equal(10000, #q.completed)
            assert.equal(1, q.completed[1])
            assert.equal(10000, q.completed[10000])
            assert.is_true(q.completedTruncated)
            assert.is_true(printed("10002 completed quests"))
        end)

        it("caps inProgress at 35 quests and 10 objectives each, text at 128 bytes", function()
            _G.C_QuestLog.GetNumQuestLogEntries = function() return 40, 40 end
            _G.C_QuestLog.GetInfo = function(i) return { questID = 1000 + i, title = "Q" .. i } end
            _G.C_QuestLog.GetQuestObjectives = function()
                local objs = {}
                for k = 1, 12 do objs[k] = { text = string.rep("x", 200), finished = true } end
                return objs
            end
            local q = payload(ns).data.quests
            assert.equal(35, #q.inProgress)
            assert.equal(10, #q.inProgress[1].objectives)
            assert.equal(128, #q.inProgress[1].objectives[1].text)
        end)

        it("sends an empty completed list when only the quest log is available", function()
            _G.C_QuestLog.GetAllCompletedQuestIDs = nil
            local q = payload(ns).data.quests
            assert.same({}, q.completed)
            assert.equal(2, #q.inProgress)
        end)

        it("leaves quests out entirely without C_QuestLog", function()
            _G.C_QuestLog = nil
            assert.is_nil(payload(ns).data.quests)
        end)
    end)
end)
