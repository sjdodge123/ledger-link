-- Raid Ledger request 2026-10-09 (planning-artifacts/LEDGERLINK-S3-REQUEST):
-- Phase 1 probes for gender, talent names/positions, completed quests and the
-- quest log, plus the size a completed-quest list would add. All in /rl probe
-- (one paste), read-only, every call pcall-wrapped. Nothing is exported.
local loadAddon = require("spec.support.load_addon")

local function report(ns)
    ns.HandleSlash("probe")
    return ns.ExportFrame.GetText()
end

local function has(text, needle)
    assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
end

describe("/rl probe: Raid Ledger S3 request", function()
    local ns
    before_each(function()
        ns = loadAddon()
        local nodes = WowStub.state.talentNodes
        nodes[101].posX, nodes[101].posY, nodes[101].entryIDs = 100, 100, { 9001 }
        nodes[102].posX, nodes[102].posY, nodes[102].entryIDs = 200, 100, { 9002 }
        nodes[103].posX, nodes[103].posY, nodes[103].entryIDs = 300, 200, { 9003 }
        C_Traits.GetEntryInfo = function(_, entryId) return { definitionID = entryId - 4000 } end
        C_Traits.GetDefinitionInfo = function(defId) return { spellID = defId + 7000 } end
        _G.C_Spell = { GetSpellName = function(id) return id == 12001 and "Mortal Strike" or "Spell " .. id end }
        _G.UnitSex = function() return 3 end
        local completed = {}
        for i = 1, 250 do completed[i] = 100 + i end
        _G.C_QuestLog = {
            GetAllCompletedQuestIDs = function() return completed end,
            GetNumQuestLogEntries = function() return 3, 2 end,
            GetInfo = function(i)
                return ({ { title = "Elwynn Forest", isHeader = true },
                    { questID = 783, title = "A Threat Within", isHeader = false },
                    { questID = 7, title = "Kobold Camp Cleanup", isHeader = false } })[i]
            end,
            GetQuestObjectives = function(id)
                if id == 783 then return { { text = "Speak to Marshal McBride", finished = false } } end
                return { { text = "Kobold Vermin slain: 4/10", finished = false } }
            end,
        }
    end)
    after_each(function()
        C_Traits.GetEntryInfo, C_Traits.GetDefinitionInfo = nil, nil
        _G.C_Spell, _G.UnitSex, _G.C_QuestLog = nil, nil, nil
    end)

    it("reports gender", function()
        has(report(ns), 'S3 UnitSex("player") = 3')
    end)

    it("reports the talent tree shape and resolves a node to its spell name", function()
        local text = report(ns)
        has(text, "S3 talents: config 7, trees 42, nodes 3 (with rank 2)")
        has(text, "posX 100..300 (3 distinct), posY 100..200 (2 distinct)")
        has(text, 'S3 talent node 101: posX=100 posY=100 activeRank=2 entryIDs={9001}'
            .. ' -> definitionID=5001 -> spellID=12001 -> name "Mortal Strike"')
    end)

    it("reports the completed-quest count with the first ids", function()
        has(report(ns), "S3 completed quests: 250 (first: 101, 102, 103, 104, 105)")
    end)

    it("reports the quest log with titles and objectives", function()
        local text = report(ns)
        has(text, "S3 quest log: GetNumQuestLogEntries() = 3, 2")
        has(text, 'S3 quest log [1] header "Elwynn Forest"')
        has(text, 'S3 quest log [2] questID=783 "A Threat Within" objectives: '
            .. '{finished = false, text = "Speak to Marshal McBride"}')
    end)

    it("measures the char token now and what a completed-quest list would add", function()
        local text = report(ns)
        local now = #assert(ns.Export.RunPages("char"))[1]
        has(text, "S3 size: char token now " .. now .. " bytes")
        assert.truthy(text:match("250 completed quest ids would add about %d+ bytes encoded %(%d+ bytes of JSON%)"), text)
    end)

    it("says missing, not crash, when the APIs aren't there", function()
        _G.UnitSex, _G.C_QuestLog, _G.C_Spell = nil, nil, nil
        C_Traits.GetEntryInfo, C_Traits.GetDefinitionInfo = nil, nil
        local text = report(ns)
        has(text, 'S3 UnitSex("player") = missing')
        has(text, "S3 completed quests: C_QuestLog.GetAllCompletedQuestIDs missing")
        has(text, "S3 quest log: C_QuestLog.GetNumQuestLogEntries missing")
        has(text, "-> definitionID=missing")
    end)

    it("says when a call errors, verbatim", function()
        _G.C_QuestLog.GetAllCompletedQuestIDs = function() error("not allowed") end
        has(report(ns), "S3 completed quests: error: ")
    end)
end)
