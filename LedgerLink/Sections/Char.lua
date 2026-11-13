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

local function completedIds()
    local all = {}
    for _, id in ipairs(ns.SafeCall(C_QuestLog.GetAllCompletedQuestIDs) or {}) do
        local v = ns.AsId(id)
        if v then all[#all + 1] = v end
    end
    table.sort(all)
    local completed = Json.array()
    for i = 1, math.min(#all, Char.QUESTS_COMPLETED_MAX) do completed[i] = all[i] end
    return completed, #all
end

local function questLog()
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
    return inProgress
end

--- Completed quest ids (ascending, capped) + the quest log, as the client
--- answers right now. nil without C_QuestLog, so the key is simply absent.
--- `total` = how many completed ids the client returned (before the cap).
function Char.Quests()
    if type(C_QuestLog) ~= "table" then return nil end
    local completed, total = completedIds()
    local quests = { completed = completed, inProgress = questLog() }
    if total > Char.QUESTS_COMPLETED_MAX then quests.completedTruncated = true end
    return quests, total
end

-- Gear + talents cache for the logout auto-export (Outbox.lua). At
-- PLAYER_LOGOUT the inventory and talent APIs already return nothing, so every
-- logout export sent `gear: []` and empty talents (2026-11-07). The last
-- non-empty read while playing is kept (this session only, in memory) and used
-- when the live read comes back empty. An empty read never replaces it.
--
-- Completed quests, the quest log and lockouts are cached the same way. Raid
-- Ledger replaces the whole char snapshot on import, so an empty list read
-- before the data loaded, during an outage or at logout (2026-11-13: an
-- outage export wiped a guild's stored text the same way) would wipe what it
-- stored: `completed: []` means "has completed no quests". An empty quest log
-- or lockout list is common in play, so an empty read of those is trusted
-- only once the game has sent that data this session (QUEST_LOG_UPDATE /
-- UPDATE_INSTANCE_INFO) and only while in the world.
Char.cache = {}

--- ROK-2125 (Raid Ledger): `quests` without `completed` = "no opinion". Only
--- a server carrying ROK-2125 accepts it (an older one rejects the string).
--- true: with no completed list read this session, leave `completed` out.
--- false: send the empty read as `[]`, as before.
Char.OMIT_UNKNOWN_COMPLETED = false

-- Whether the game has sent this data this session (never persisted).
Char.loaded = { questLog = false, instanceInfo = false }
-- Between PLAYER_LEAVING_WORLD and PLAYER_ENTERING_WORLD (loading screen,
-- logout or a disconnect) an empty read is never trusted.
local leavingWorld = false

-- Nodes, not just a config id: a config id with no readable nodes is the
-- trait APIs not answering yet, and must not replace a populated cache.
local function hasTalents(t)
    return type(t) == "table" and #t.nodes > 0
end

--- Live gear, kept in the cache; the cached gear when the live read is empty.
function Char.GearOrCached()
    local gear = Char.Gear()
    if #gear > 0 then
        Char.cache.gear = gear
        return gear
    end
    return Char.cache.gear or gear
end

--- Live talents, kept in the cache; the cached talents when the live read is empty.
function Char.TalentsOrCached()
    local talents = Char.Talents()
    if hasTalents(talents) then
        Char.cache.talents = talents
        return talents
    end
    return Char.cache.talents or talents
end

--- Live lockouts, kept in the cache; an empty read is trusted only after
--- UPDATE_INSTANCE_INFO this session and while in the world, else the cached
--- lockouts that have not reset yet (else the empty read: the key is required).
function Char.LockoutsOrCached()
    local lockouts = Char.Lockouts()
    if #lockouts > 0 or (Char.loaded.instanceInfo and not leavingWorld) then
        Char.cache.lockouts = lockouts
        return lockouts
    end
    local cached = Char.cache.lockouts
    if not cached then return lockouts end
    local now = ns.SafeCall(GetServerTime) or time()
    local live = Json.array()
    for _, row in ipairs(cached) do
        if row.resetAt > now then live[#live + 1] = row end
    end
    return live
end

--- Live quests, with each part kept in the cache: a non-empty completed list
--- always; the quest log when non-empty, or empty after QUEST_LOG_UPDATE this
--- session while in the world. An empty completed read is never trusted: the
--- cached list, else "no opinion" (Char.OMIT_UNKNOWN_COMPLETED) or `[]`.
-- The live quest log, kept in the cache; the cached log for an untrusted empty read.
local function questLogOrCached(inProgress)
    if #inProgress > 0 or (Char.loaded.questLog and not leavingWorld) then
        Char.cache.inProgress = inProgress
        return inProgress
    end
    return Char.cache.inProgress or inProgress
end

function Char.QuestsOrCached()
    local quests, total = Char.Quests()
    if not quests then return nil end
    local cache = Char.cache
    if total > 0 then
        cache.completed = { ids = quests.completed, truncated = quests.completedTruncated }
    elseif cache.completed then
        quests.completed, quests.completedTruncated = cache.completed.ids, cache.completed.truncated
    elseif Char.OMIT_UNKNOWN_COMPLETED then
        quests.completed = nil
    end
    quests.inProgress = questLogOrCached(quests.inProgress)
    return quests, total
end

local function reportTruncated(quests, total)
    if total and total > Char.QUESTS_COMPLETED_MAX then
        ns.Print(string.format("You have %d completed quests; Raid Ledger keeps %d, so the lowest %d ids were exported.",
            total, Char.QUESTS_COMPLETED_MAX, Char.QUESTS_COMPLETED_MAX))
    end
    return quests
end

function Char.Build()
    return {
        gear = Char.GearOrCached(),
        talents = Char.TalentsOrCached(),
        lockouts = Char.LockoutsOrCached(),
        quests = reportTruncated(Char.QuestsOrCached()),
        mailworthy = ns.Mailworthy.Block(), -- nil (no key) without Mailworthy or a guild
    }
end

-- Refresh the cache on the events where the APIs answer. TRAIT_CONFIG_UPDATED
-- and PLAYER_TALENT_UPDATE may not exist on Forever: registered under pcall.
local REFRESH = {
    PLAYER_ENTERING_WORLD = { gear = true, talents = true, quests = true, lockouts = true },
    -- The last read before logout (an empty quest / lockout read is not trusted here).
    PLAYER_LEAVING_WORLD = { gear = true, talents = true, quests = true, lockouts = true },
    PLAYER_EQUIPMENT_CHANGED = { gear = true },
    TRAIT_CONFIG_UPDATED = { talents = true },
    PLAYER_TALENT_UPDATE = { talents = true },
    QUEST_LOG_UPDATE = { quests = true, loaded = "questLog" },
    UPDATE_INSTANCE_INFO = { lockouts = true, loaded = "instanceInfo" },
}

--- Throttle for the completed-quest scan on QUEST_LOG_UPDATE (it fires
--- often; the scan sorts thousands of ids). The quest log itself is re-read
--- on every one, so a log emptied by the last turn-in is never missed.
Char.QUEST_REFRESH_SECONDS = 10
local questsReadAt

function Char.OnEvent(event)
    local what = REFRESH[event]
    if not what then return end
    if event == "PLAYER_ENTERING_WORLD" then leavingWorld = false end
    if event == "PLAYER_LEAVING_WORLD" then leavingWorld = true end
    if what.loaded then
        if leavingWorld then return end
        Char.loaded[what.loaded] = true
    end
    if what.gear then Char.GearOrCached() end
    if what.talents then Char.TalentsOrCached() end
    if what.lockouts then Char.LockoutsOrCached() end
    if what.quests then
        local now = ns.SafeCall(GetServerTime) or time()
        -- Unthrottled until a completed list is cached: never skip the first good read.
        if not what.loaded or not Char.cache.completed or not questsReadAt
            or now - questsReadAt >= Char.QUEST_REFRESH_SECONDS then
            questsReadAt = now
            Char.QuestsOrCached()
        elseif type(C_QuestLog) == "table" then
            questLogOrCached(questLog())
        end
    end
end

local events = CreateFrame("Frame")
Char.frame = events
for event in pairs(REFRESH) do pcall(events.RegisterEvent, events, event) end
events:SetScript("OnEvent", function(_, event) Char.OnEvent(event) end)

ns.Export.RegisterSection("char", Char.Build)
