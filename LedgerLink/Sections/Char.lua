-- Character section: gear, talents, lockouts (contract AddonCharDataSchema).
local _, ns = ...

local Json = ns.Json
local Char = {}
ns.Char = Char

local MAX_TALENT_NODES = 200
local MAX_LOCKOUTS = 100
local MAX_IMPORT_STRING = 2048
local MAX_LINK = 512

local function itemIdFromLink(link)
    local id = link and string.match(link, "item:(%d+)")
    return id and ns.AsId(tonumber(id)) or nil
end

local function itemLevel(link)
    if not link or type(C_Item) ~= "table" then return nil end
    return ns.AsId(ns.SafeCall(C_Item.GetDetailedItemLevelInfo, link))
end

function Char.Gear()
    local gear = Json.array()
    for slot = 1, 19 do
        local link = ns.SafeCall(GetInventoryItemLink, "player", slot)
        if type(link) ~= "string" then link = nil end
        local itemId = ns.AsId(ns.SafeCall(GetInventoryItemID, "player", slot)) or itemIdFromLink(link)
        if link or itemId then
            gear[#gear + 1] = {
                slot = slot,
                itemId = itemId,
                link = link and #link <= MAX_LINK and link or nil,
                ilvl = itemLevel(link),
            }
        end
    end
    return gear
end

local function round(x) return math.floor(x + 0.5) end

-- entryID -> definitionID -> spellID -> name (Raid Ledger ROK-1742); nil when
-- any step is missing.
local function nodeSpell(configId, entryId)
    local entry = ns.SafeCall(C_Traits.GetEntryInfo, configId, entryId)
    local defId = type(entry) == "table" and entry.definitionID or nil
    local def = defId and ns.SafeCall(C_Traits.GetDefinitionInfo, defId) or nil
    local spellId = type(def) == "table" and ns.AsId(def.spellID) or nil
    if not spellId or spellId < 1 then return nil end
    local nameFn = (type(C_Spell) == "table" and C_Spell.GetSpellName) or GetSpellInfo
    return spellId, ns.Clip(ns.SafeCall(nameFn, spellId), 64)
end

-- Every node, rank 0 included (Raid Ledger draws the full grid, ROK-1744).
local function nodeRow(configId, nodeId)
    local info = ns.SafeCall(C_Traits.GetNodeInfo, configId, nodeId)
    if type(info) ~= "table" then return nil end
    local row = { nodeId = ns.AsId(nodeId), rank = ns.AsId(info.activeRank or info.ranksPurchased) or 0 }
    -- The chosen entry; for an unchosen node only an unambiguous single entry.
    local entry = type(info.activeEntry) == "table" and info.activeEntry.entryID or nil
    if not entry and type(info.entryIDs) == "table" and #info.entryIDs == 1 then entry = info.entryIDs[1] end
    row.entryId = ns.AsId(entry)
    if row.entryId then row.spellId, row.name = nodeSpell(configId, row.entryId) end
    local maxRanks = ns.AsId(info.maxRanks)
    if maxRanks and maxRanks >= 1 and maxRanks <= 255 then row.maxRanks = maxRanks end
    if type(info.posX) == "number" and type(info.posY) == "number" then
        row.posX, row.posY = ns.AsId(round(info.posX)), ns.AsId(round(info.posY))
    end
    return row
end

-- tree / row / col hints by the shared rule (TalentGrid, CONTRACT.md §3); a
-- hint outside the contract's range is dropped, the raw position stays.
local function addGridHints(nodes)
    ns.TalentGrid.Assign(nodes)
    for _, n in ipairs(nodes) do
        if n.tree and not (n.tree <= 2 and n.row >= 0 and n.row <= 9 and n.col >= 0 and n.col <= 3) then
            n.tree, n.row, n.col = nil, nil, nil
        end
    end
end

local function talentNodes(configId)
    local nodes = Json.array()
    local config = ns.SafeCall(C_Traits.GetConfigInfo, configId)
    local trees = type(config) == "table" and config.treeIDs or {}
    for _, treeId in ipairs(trees) do
        local treeNodes = ns.SafeCall(C_Traits.GetTreeNodes, treeId) or {}
        for _, nodeId in ipairs(treeNodes) do
            local row = ns.AsId(nodeId) and nodeRow(configId, nodeId)
            if row and #nodes < MAX_TALENT_NODES then nodes[#nodes + 1] = row end
        end
    end
    addGridHints(nodes)
    return nodes
end

function Char.Talents()
    local talents = { nodes = Json.array() }
    if type(C_ClassTalents) ~= "table" or type(C_Traits) ~= "table" then return talents end
    local configId = ns.AsId(ns.SafeCall(C_ClassTalents.GetActiveConfigID))
    if not configId then return talents end
    talents.configId = configId
    local importString = ns.SafeCall(C_Traits.GenerateImportString, configId)
    if type(importString) == "string" and importString ~= "" and #importString <= MAX_IMPORT_STRING then
        talents.importString = importString
    end
    talents.nodes = talentNodes(configId)
    return talents
end

local function lockoutRow(i, now)
    local name, _, reset, difficultyId, locked, _, _, _, _, _, numEncounters,
        encounterProgress, _, instanceId = ns.SafeCall(GetSavedInstanceInfo, i)
    instanceId, difficultyId = ns.AsId(instanceId), ns.AsId(difficultyId)
    if not locked or not instanceId or not difficultyId then return nil end
    if type(reset) ~= "number" or reset <= 0 then return nil end
    return {
        name = ns.Clip(name, 128) or "",
        instanceId = instanceId,
        difficultyId = difficultyId,
        resetAt = math.floor(now + reset),
        killed = ns.AsId(encounterProgress) or 0,
        total = ns.AsId(numEncounters) or 0,
    }
end

function Char.Lockouts()
    local lockouts = Json.array()
    local count = ns.AsId(ns.SafeCall(GetNumSavedInstances)) or 0
    local now = ns.SafeCall(GetServerTime) or time()
    for i = 1, count do
        local row = lockoutRow(i, now)
        if row and #lockouts < MAX_LOCKOUTS then lockouts[#lockouts + 1] = row end
    end
    return lockouts
end

-- Contract limits (wow-addon-export.schema.ts, ROK-1742).
Char.QUESTS_COMPLETED_MAX = 10000
Char.QUESTS_IN_PROGRESS_MAX = 35
Char.QUEST_OBJECTIVES_MAX = 10

local function objectives(questId)
    local list = ns.SafeCall(C_QuestLog.GetQuestObjectives, questId)
    if type(list) ~= "table" or #list == 0 then return nil end
    local out = Json.array()
    for k = 1, math.min(#list, Char.QUEST_OBJECTIVES_MAX) do
        local o = type(list[k]) == "table" and list[k] or {}
        out[k] = { text = ns.Clip(o.text, 128) or "", done = o.finished == true,
            have = ns.AsId(o.numFulfilled), need = ns.AsId(o.numRequired) }
    end
    return out
end

--- Completed quest ids (ascending, capped) + the quest log. nil without
--- C_QuestLog, so the key is simply absent.
function Char.Quests()
    if type(C_QuestLog) ~= "table" then return nil end
    local all = {}
    for _, id in ipairs(ns.SafeCall(C_QuestLog.GetAllCompletedQuestIDs) or {}) do
        local v = ns.AsId(id)
        if v then all[#all + 1] = v end
    end
    table.sort(all)
    local completed = Json.array()
    for i = 1, math.min(#all, Char.QUESTS_COMPLETED_MAX) do completed[i] = all[i] end

    local inProgress = Json.array()
    local entries = ns.AsId(ns.SafeCall(C_QuestLog.GetNumQuestLogEntries)) or 0
    for i = 1, math.min(entries, 200) do
        if #inProgress >= Char.QUESTS_IN_PROGRESS_MAX then break end
        local info = ns.SafeCall(C_QuestLog.GetInfo, i)
        local questId = type(info) == "table" and not info.isHeader and ns.AsId(info.questID) or nil
        if questId then
            inProgress[#inProgress + 1] = { questId = questId, title = ns.Clip(info.title, 128),
                objectives = objectives(questId) }
        end
    end

    local quests = { completed = completed, inProgress = inProgress }
    if #all > Char.QUESTS_COMPLETED_MAX then
        quests.completedTruncated = true
        ns.Print(string.format("You have %d completed quests; Raid Ledger keeps %d, so the lowest %d ids were exported.",
            #all, Char.QUESTS_COMPLETED_MAX, Char.QUESTS_COMPLETED_MAX))
    end
    return quests
end

function Char.Build()
    return {
        gear = Char.Gear(),
        talents = Char.Talents(),
        lockouts = Char.Lockouts(),
        quests = Char.Quests(),
    }
end

ns.Export.RegisterSection("char", Char.Build)
