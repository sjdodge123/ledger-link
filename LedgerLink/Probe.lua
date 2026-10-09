-- /rl probe: runs the beta checks (the README's "Beta unknowns") and shows the
-- results as plain text in the copy box, so a tester pastes one block instead
-- of typing /dump lines. Read-only calls only; every call is pcall-wrapped and
-- a missing function is reported, not assumed. Not a Raid Ledger import string.
local _, ns = ...

local Probe = {}
ns.Probe = Probe

local MAX_ITEMS = 40

local function format(v, depth)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    if depth >= 2 then return "{...}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for i, k in ipairs(keys) do
        if i > MAX_ITEMS then
            parts[#parts + 1] = "..."
            break
        end
        parts[#parts + 1] = tostring(k) .. " = " .. format(v[k], depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function formatResults(results, n)
    if n == 0 then return "(no values)" end
    local out = {}
    for i = 1, n do out[i] = format(results[i], 0) end
    return table.concat(out, ", ")
end

-- Looks up "C_GameRules.IsHardcoreActive" without erroring when a table is missing.
local function resolve(path)
    local v = _G
    for part in path:gmatch("[^.]+") do
        if type(v) ~= "table" then return nil end
        v = v[part]
    end
    return v
end

-- { label, function path, args..., redact = { [i] = replacement } }
local CALLS = {
    { "GetBuildInfo" },
    { "GetCurrentRegion" },
    { "GetCurrentRegionName" },
    { "GetCVar", "portal" },
    { "GetLocale" },
    { "GetRealmName" },
    { "GetNormalizedRealmName" },
    { "UnitGUID", "player" },
    { "GetUnitName", "player", true },
    { "UnitFullName", "player" },
    { "UnitName", "player" },
    { "UnitClass", "player" },
    { "UnitRace", "player" },
    { "UnitLevel", "player" },
    { "UnitFactionGroup", "player" },
    { "C_GameRules.GetForeverExperiencePreset" },
    { "C_GameRules.GetActiveGameMode" },
    { "C_GameRules.GetCurrentGameModeRecordID" },
    { "C_GameRules.GetCurrentGameModeDisplayInfo" },
    { "C_GameRules.IsStandard" },
    { "C_GameRules.IsHardcoreActive" },
    { "C_GameRules.IsSelfFoundAllowed" },
    { "C_GameRules.IsPlunderstorm" },
    { "GetGuildInfo", "player" },
    { "GetNumGuildMembers" },
    -- Slot 8 is the officer note: replaced before anything is formatted.
    { "GetGuildRosterInfo", 1, redact = { [8] = "<officer note not read>" } },
    { "GetGuildRosterLastOnline", 1 },
    { "GetInstanceInfo" },
    { "GetServerTime" },
    { "GetNumSavedInstances" },
    { "C_ClassTalents.GetActiveConfigID" },
}

-- Tables whose presence matters on their own.
local PRESENCE = {
    "C_EncodingUtil", "C_EncodingUtil.CompressString", "C_EncodingUtil.EncodeBase64",
    "Enum.CompressionMethod", "C_GuildInfo", "C_GuildInfo.GuildRoster", "GuildRoster",
    "C_Traits", "C_Item.GetDetailedItemLevelInfo", "C_Seasons",
}

local function describeCall(spec)
    local path = spec[1]
    local args = {}
    for i = 2, #spec do args[#args + 1] = format(spec[i], 0) end
    local label = path .. "(" .. table.concat(args, ", ") .. ")"
    local fn = resolve(path)
    if type(fn) ~= "function" then return label .. " = missing" end
    local results = { pcall(fn, unpack(spec, 2)) }
    if not results[1] then return label .. " = error: " .. tostring(results[2]) end
    local n = table.maxn(results) - 1
    local values = {}
    for i = 1, n do values[i] = results[i + 1] end
    for i, replacement in pairs(spec.redact or {}) do
        if i <= n then values[i] = replacement end
    end
    return label .. " = " .. formatResults(values, n)
end

-- Raid Ledger request 2026-10-09 (planning-artifacts/LEDGERLINK-S3-REQUEST):
-- gender, talent names/positions, completed quests, quest log, and the size a
-- completed-quest list would add. Lines start with "S3". Read-only; each call
-- is pcall-wrapped and reported as missing / error: <text> / its value.

local function call(fn, ...)
    if type(fn) ~= "function" then return "missing" end
    local results = { pcall(fn, ...) }
    if not results[1] then return "error", tostring(results[2]) end
    return "ok", unpack(results, 2, table.maxn(results))
end

local function list(t)
    if type(t) ~= "table" then return format(t, 0) end
    local out = {}
    for i, v in ipairs(t) do out[i] = format(v, 1) end
    return "{" .. table.concat(out, ", ") .. "}"
end

local function field(fn, key, ...)
    local status, value = call(fn, ...)
    if status ~= "ok" then return nil, status == "missing" and "missing" or ("error: " .. tostring(value)) end
    if type(value) ~= "table" then return nil, "nil" end
    return value[key], tostring(value[key])
end

local function s3Talents(lines)
    local traits = C_Traits
    if type(traits) ~= "table" then
        lines[#lines + 1] = "S3 talents: C_Traits missing"
        return
    end
    local _, configId = call(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
    local status, config = call(traits.GetConfigInfo, configId)
    if status ~= "ok" or type(config) ~= "table" then
        lines[#lines + 1] = "S3 talents: GetConfigInfo(" .. tostring(configId) .. ") = " .. tostring(status)
        return
    end
    local trees, nodes = config.treeIDs or {}, {}
    for _, treeId in ipairs(trees) do
        local _, treeNodes = call(traits.GetTreeNodes, treeId)
        for _, nodeId in ipairs(type(treeNodes) == "table" and treeNodes or {}) do
            local _, info = call(traits.GetNodeInfo, configId, nodeId)
            nodes[#nodes + 1] = { id = nodeId, info = type(info) == "table" and info or {} }
        end
    end
    local ranked, xs, ys = 0, {}, {}
    local minX, maxX, minY, maxY
    for _, n in ipairs(nodes) do
        local i = n.info
        if (tonumber(i.activeRank) or 0) > 0 or (tonumber(i.ranksPurchased) or 0) > 0 then ranked = ranked + 1 end
        if type(i.posX) == "number" then
            xs[i.posX] = (xs[i.posX] or 0) + 1
            minX, maxX = math.min(minX or i.posX, i.posX), math.max(maxX or i.posX, i.posX)
        end
        if type(i.posY) == "number" then
            ys[i.posY] = (ys[i.posY] or 0) + 1
            minY, maxY = math.min(minY or i.posY, i.posY), math.max(maxY or i.posY, i.posY)
        end
    end
    local function distinct(t) local c = 0 for _ in pairs(t) do c = c + 1 end return c end
    lines[#lines + 1] = string.format("S3 talents: config %s, trees %s, nodes %d (with rank %d); "
        .. "posX %s..%s (%d distinct), posY %s..%s (%d distinct)",
        tostring(configId), table.concat(trees, ","), #nodes, ranked,
        tostring(minX), tostring(maxX), distinct(xs), tostring(minY), tostring(maxY), distinct(ys))
    -- Every distinct position with its node count: enough to map posX/posY to
    -- sub-tree, column and row.
    local function values(t)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys)
        for k, v in ipairs(keys) do keys[k] = string.format("%s(%d)", tostring(v), t[v]) end
        return table.concat(keys, ", ")
    end
    lines[#lines + 1] = "S3 talent posX values: " .. values(xs)
    lines[#lines + 1] = "S3 talent posY values: " .. values(ys)
    -- Sample up to 3 nodes that have entries (those can resolve to a spell).
    local samples = {}
    for _, n in ipairs(nodes) do
        if #samples < 3 and type(n.info.entryIDs) == "table" and n.info.entryIDs[1] then samples[#samples + 1] = n end
    end
    if #samples == 0 then
        lines[#lines + 1] = "S3 talent nodes: none have entryIDs"
    end
    for _, n in ipairs(samples) do
        local i = n.info
        local defId, defText = field(traits.GetEntryInfo, "definitionID", configId, i.entryIDs[1])
        local spellId, spellText = nil, "none (no definitionID)"
        if defId ~= nil then spellId, spellText = field(traits.GetDefinitionInfo, "spellID", defId) end
        local nameText = "none (no spellID)"
        if spellId ~= nil then
            local nameFn = (type(C_Spell) == "table" and C_Spell.GetSpellName) or GetSpellInfo
            local nameStatus, name = call(nameFn, spellId)
            nameText = nameStatus == "ok" and format(name, 0) or nameStatus
        end
        lines[#lines + 1] = string.format("S3 talent node %s: posX=%s posY=%s activeRank=%s entryIDs=%s"
            .. " -> definitionID=%s -> spellID=%s -> name %s",
            tostring(n.id), tostring(i.posX), tostring(i.posY), tostring(i.activeRank), list(i.entryIDs),
            defText, spellText, nameText)
    end
end

local function s3Quests(lines)
    local log = type(C_QuestLog) == "table" and C_QuestLog or {}
    local status, ids = call(log.GetAllCompletedQuestIDs)
    local completed
    if status == "missing" then
        lines[#lines + 1] = "S3 completed quests: C_QuestLog.GetAllCompletedQuestIDs missing"
    elseif status == "error" then
        lines[#lines + 1] = "S3 completed quests: error: " .. tostring(ids)
    elseif type(ids) ~= "table" then
        lines[#lines + 1] = "S3 completed quests: returned " .. format(ids, 0)
    else
        completed = ids
        local first = {}
        for k = 1, math.min(5, #ids) do first[k] = tostring(ids[k]) end
        lines[#lines + 1] = string.format("S3 completed quests: %d (first: %s)", #ids, table.concat(first, ", "))
    end

    local nStatus, numEntries, numQuests = call(log.GetNumQuestLogEntries)
    if nStatus ~= "ok" then
        lines[#lines + 1] = "S3 quest log: C_QuestLog.GetNumQuestLogEntries " .. nStatus
    else
        lines[#lines + 1] = "S3 quest log: GetNumQuestLogEntries() = " .. tostring(numEntries) .. ", " .. tostring(numQuests)
        for i = 1, math.min(tonumber(numEntries) or 0, 8) do
            local iStatus, info = call(log.GetInfo, i)
            if iStatus ~= "ok" or type(info) ~= "table" then
                lines[#lines + 1] = string.format("S3 quest log [%d] GetInfo = %s", i, iStatus == "ok" and "nil" or iStatus)
            elseif info.isHeader then
                lines[#lines + 1] = string.format("S3 quest log [%d] header %s", i, format(info.title, 0))
            else
                local oStatus, objectives = call(log.GetQuestObjectives, info.questID)
                local objText = oStatus ~= "ok" and oStatus or {}
                if type(objText) == "table" then
                    for k, o in ipairs(type(objectives) == "table" and objectives or {}) do objText[k] = format(o, 0) end
                    objText = table.concat(objText, ", ")
                end
                lines[#lines + 1] = string.format("S3 quest log [%d] questID=%s %s objectives: %s",
                    i, tostring(info.questID), format(info.title, 0), objText)
            end
        end
    end
    return completed
end

-- Raid Ledger ROK-1748: do vanilla dungeon quests keep their Classic ids on
-- Forever? Classic ids for a few dungeon quests, checked against the
-- completed list (yes / no). Run after doing one of these dungeons.
local DUNGEON_QUESTS = {
    { "Ragefire Chasm", { 5728, 5761 } },
    { "Deadmines", { 141, 166 } },
    { "Wailing Caverns", { 2040, 2039 } },
    { "Stockade", { 1053 } },
}

local function s3DungeonQuests(lines, completed)
    if not completed then
        lines[#lines + 1] = "S3 dungeon quest ids: unavailable (no completed-quest list)"
        return
    end
    local done = {}
    for _, id in ipairs(completed) do done[id] = true end
    local groups = {}
    for _, d in ipairs(DUNGEON_QUESTS) do
        local parts = { d[1] }
        for _, id in ipairs(d[2]) do parts[#parts + 1] = id .. "=" .. (done[id] and "yes" or "no") end
        groups[#groups + 1] = table.concat(parts, " ")
    end
    lines[#lines + 1] = "S3 dungeon quest ids: " .. table.concat(groups, " | ")
end

local function s3Size(lines, completed)
    local pages, err = ns.Export.RunPages("char")
    if not pages then
        lines[#lines + 1] = "S3 size: char export failed: " .. tostring(err)
        return
    end
    local line = string.format("S3 size: char token now %d bytes", #pages[1])
    if completed then
        local parts = {}
        for i, id in ipairs(completed) do parts[i] = tostring(id) end
        local json = '"quests":{"completed":[' .. table.concat(parts, ",") .. "]}"
        line = line .. string.format("; %d completed quest ids would add about %s bytes encoded (%d bytes of JSON)",
            #completed, tostring(ns.Export.EncodedSize(json) or "?"), #json)
    end
    lines[#lines + 1] = line
end

local function s3Lines(lines)
    local sStatus, sex = call(UnitSex, "player")
    lines[#lines + 1] = 'S3 UnitSex("player") = ' .. (sStatus == "ok" and format(sex, 0) or sStatus)
    s3Talents(lines)
    local completed = s3Quests(lines)
    s3DungeonQuests(lines, completed)
    s3Size(lines, completed)
end

--- Plain-text report, one line per check.
function Probe.Report()
    local lines = {
        string.format("LedgerLink %s probe at %s", ns.VERSION, date("%Y-%m-%d %H:%M")),
        string.format("settings: ruleset = %s, region = %s, recorded pulls = %d",
            tostring(LedgerLinkCharDB and LedgerLinkCharDB.ruleset), tostring(LedgerLinkDB and LedgerLinkDB.region),
            #ns.Raid.Pulls()),
    }
    for _, line in ipairs(ns.Blocked.Lines()) do lines[#lines + 1] = line end
    for _, spec in ipairs(CALLS) do lines[#lines + 1] = describeCall(spec) end
    for _, path in ipairs(PRESENCE) do
        local v = resolve(path)
        lines[#lines + 1] = path .. " = " .. (v == nil and "missing" or type(v))
    end
    s3Lines(lines)
    return table.concat(lines, "\n")
end

Probe.FOOTER = "Click the text, Ctrl+C, then paste this report to the addon developer (not into Raid Ledger)"

function Probe.Show()
    ns.ExportFrame.Show("beta probe", Probe.Report(), Probe.FOOTER)
end
