-- /rl probe "S4" lines (operator 2026-10-09: "add as much info as possible"
-- before a dungeon run): group + instance, recorded pulls, full quest log meta
-- and tags, dungeon quest flags, lockouts, the computed talent grid, discovery
-- of Forever's "legacy talents" / "legacy challenges" (global name scan,
-- C_Traits systems, achievement categories) and character extras. Read-only,
-- every call pcall-wrapped; nothing is exported.
local loadAddon = require("spec.support.load_addon")

local function report(ns)
    ns.HandleSlash("probe")
    return ns.ExportFrame.GetText()
end

local function has(text, needle)
    assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
end

local STUBBED = { "IsInGroup", "IsInRaid", "GetNumSubgroupMembers", "UnitExists", "C_Map", "EJ_GetInstanceForMap",
    "EJ_GetInstanceInfo", "GetDungeonDifficultyID", "GetZoneText", "C_QuestLog", "UnitSex", "C_Spell",
    "C_LegacyTalents", "LegacyChallengeFrame", "GetCategoryList", "GetCategoryInfo", "GetCategoryNumAchievements",
    "GetAchievementInfo", "GetTotalAchievementPoints", "GetNumCompletedAchievements", "GetAverageItemLevel",
    "UnitXP", "UnitXPMax", "GetXPExhaustion", "GetProfessions", "GetNumSkillLines", "GetSkillLineInfo" }

describe("/rl probe: S4 dungeon + legacy discovery", function()
    local ns, saved
    before_each(function()
        ns = loadAddon()
        -- Restore, don't nil: the shared stub defines some of these (IsInRaid).
        saved = {}
        for _, name in ipairs(STUBBED) do saved[name] = rawget(_G, name) end
    end)
    after_each(function()
        for _, name in ipairs(STUBBED) do _G[name] = saved[name] end
        C_Traits.GetConfigIDBySystemID, C_Traits.GetEntryInfo, C_Traits.GetDefinitionInfo = nil, nil, nil
    end)

    it("reports the group and whether party members' identities are readable", function()
        _G.IsInGroup = function() return true end
        _G.IsInRaid = function() return false end
        _G.GetNumSubgroupMembers = function() return 2 end
        _G.UnitExists = function(u) return u == "party1" or u == "party2" end
        WowStub.state.units = { party1 = { guid = "Player-1-0000ABCD", name = "Pal One" }, party2 = { name = "Pal Two" } }
        local text = report(ns)
        has(text, "S4 IsInGroup() = true")
        has(text, "S4 party1: exists guid=readable name=readable")
        has(text, "S4 party2: exists guid=unreadable name=readable")
        assert.falsy(text:find("Player-1-0000ABCD", 1, true), "party GUIDs are never printed")
    end)

    it("resolves the instance map and dungeon-guide entry", function()
        _G.C_Map = { GetBestMapForUnit = function() return 213 end,
            GetMapInfo = function(id) return { mapID = id, name = "Ragefire Chasm", mapType = 4 } end }
        _G.EJ_GetInstanceForMap = function() return 226 end
        _G.EJ_GetInstanceInfo = function() return "Ragefire Chasm", "A cave", 0 end
        _G.GetDungeonDifficultyID = function() return 1 end
        local text = report(ns)
        has(text, 'S4 map: C_Map.GetBestMapForUnit("player") = 213 -> GetMapInfo = {mapID = 213, mapType = 4, name = "Ragefire Chasm"}')
        has(text, 'S4 dungeon guide: EJ_GetInstanceForMap(213) = 226 -> EJ_GetInstanceInfo = "Ragefire Chasm", "A cave", 0')
        has(text, "S4 GetDungeonDifficultyID() = 1")
    end)

    it("lists recorded pulls", function()
        WowStub.raid(5)
        ns.Raid.OnEvent("ENCOUNTER_START", 1443, "Oggleflint", 1, 5)
        ns.Raid.OnEvent("ENCOUNTER_END", 1443, "Oggleflint", 1, 5, 1)
        has(report(ns), 'S4 pull 1: encounterId=1443 "Oggleflint" difficultyId=1 groupSize=5 success=true roster=5')
    end)

    it("lists every quest-log quest with level, group, tag and completion", function()
        _G.C_QuestLog = {
            GetNumQuestLogEntries = function() return 2, 1 end,
            GetInfo = function(i)
                return ({ { title = "Ragefire Chasm", isHeader = true },
                    { questID = 5728, title = "Hidden Enemies", level = 16, suggestedGroup = 5, frequency = 0,
                        isComplete = false } })[i]
            end,
            GetQuestTagInfo = function() return { tagID = 81, tagName = "Dungeon" } end,
            IsQuestFlaggedCompleted = function(id) return id == 5761 end,
            GetAllCompletedQuestIDs = function() return { 5761 } end,
        }
        local text = report(ns)
        has(text, 'S4 quest 5728 "Hidden Enemies": level=16 suggestedGroup=5 frequency=0 isComplete=false'
            .. ' tag={tagID = 81, tagName = "Dungeon"}')
        has(text, "S4 dungeon quest flags (IsQuestFlaggedCompleted): Ragefire Chasm 5728=no 5761=yes")
    end)

    it("prints every talent node with its computed tree / row / col, rank and name", function()
        local n = WowStub.state.talentNodes
        n[101].posX, n[101].posY, n[101].entryIDs, n[101].maxRanks = 1020, 2130, { 9001 }, 3
        n[102].posX, n[102].posY, n[102].entryIDs, n[102].maxRanks = 5030, 2730, { 9002 }, 1
        C_Traits.GetEntryInfo = function(_, e) return { definitionID = e - 4000 } end
        C_Traits.GetDefinitionInfo = function(d) return { spellID = d + 7000 } end
        _G.C_Spell = { GetSpellName = function(id) return "Spell " .. id end }
        local text = report(ns)
        has(text, 'S4 talent t0 r0 c0: "Spell 12001" rank 2/3 (node 101)')
        has(text, 'S4 talent t1 r1 c0: "Spell 12002" rank 0/1 (node 102)')
    end)

    it("discovers globals named like legacy / forever / challenge without calling them", function()
        local called = false
        _G.C_LegacyTalents = { GetThing = function() called = true end, GetOther = function() end }
        _G.LegacyChallengeFrame = { Show = function() end }
        local text = report(ns)
        has(text, "S4 globals matching legacy|forever|challenge:")
        has(text, "C_LegacyTalents(table)")
        has(text, "LegacyChallengeFrame(table)")
        has(text, "S4 C_LegacyTalents functions: GetOther, GetThing")
        assert.is_false(called)
    end)

    it("scans C_Traits systems for extra talent configs (where legacy talents may live)", function()
        C_Traits.GetConfigIDBySystemID = function(id) return id == 42 and 555 or 0 end
        local old = C_Traits.GetConfigInfo
        C_Traits.GetConfigInfo = function(id)
            if id == 555 then return { ID = 555, name = "Legacy", type = 3, treeIDs = { 42 } } end
            return old(id)
        end
        local text = report(ns)
        C_Traits.GetConfigInfo = old
        has(text, 'S4 trait system 42: config 555 {ID = 555, name = "Legacy", treeIDs = {...}, type = 3} trees 42 (3 nodes)')
    end)

    it("lists achievement categories and details legacy / challenge ones", function()
        _G.GetCategoryList = function() return { 92, 15001 } end
        _G.GetCategoryInfo = function(id) return id == 15001 and "Legacy Challenges" or "General", -1, 0 end
        _G.GetCategoryNumAchievements = function() return 3, 1 end
        _G.GetAchievementInfo = function(cat, i)
            if cat == 15001 and i == 1 then return 50001, "Ancient Lore", 10, true, 10, 9, 26, "Learn things" end
        end
        _G.GetTotalAchievementPoints = function() return 120 end
        local text = report(ns)
        has(text, "S4 GetTotalAchievementPoints() = 120")
        has(text, 'S4 achievement categories: 92 "General", 15001 "Legacy Challenges"')
        has(text, 'S4 achievement category 15001 "Legacy Challenges": GetCategoryNumAchievements = 3, 1')
        has(text, 'S4 achievement 50001 "Ancient Lore" points=10 completed=true description="Learn things"')
    end)

    it("reports character extras", function()
        _G.GetAverageItemLevel = function() return 12.5, 11 end
        _G.UnitXP = function() return 900 end
        _G.UnitXPMax = function() return 1400 end
        _G.GetNumSkillLines = function() return 1 end
        _G.GetSkillLineInfo = function() return "Mining", false, false, 15, 0, 0, 75 end
        local text = report(ns)
        has(text, "S4 GetAverageItemLevel() = 12.5, 11")
        has(text, 'S4 UnitXP("player") = 900')
        has(text, 'S4 GetSkillLineInfo(1) = "Mining", false, false, 15, 0, 0, 75')
    end)

    it("degrades to missing for every new section when nothing is there", function()
        local text = report(ns)
        has(text, "S4 IsInGroup() = missing")
        has(text, "S4 map: C_Map.GetBestMapForUnit missing")
        has(text, "S4 pulls: none recorded")
        has(text, "S4 trait systems: C_Traits.GetConfigIDBySystemID missing")
        has(text, "S4 achievement categories: GetCategoryList missing")
    end)
end)
