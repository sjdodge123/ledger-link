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

local function nodeRow(configId, nodeId)
    local info = ns.SafeCall(C_Traits.GetNodeInfo, configId, nodeId)
    if type(info) ~= "table" then return nil end
    local rank = ns.AsId(info.activeRank or info.ranksPurchased)
    if not rank or rank < 1 then return nil end
    local entry = type(info.activeEntry) == "table" and info.activeEntry.entryID or nil
    return { nodeId = ns.AsId(nodeId), rank = rank, entryId = ns.AsId(entry) }
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

function Char.Build()
    return {
        gear = Char.Gear(),
        talents = Char.Talents(),
        lockouts = Char.Lockouts(),
    }
end

ns.Export.RegisterSection("char", Char.Build)
