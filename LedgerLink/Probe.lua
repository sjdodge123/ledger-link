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

-- ---------------------------------------------------------------------------
-- "S4": as much as one probe can tell (operator 2026-10-09, before a dungeon
-- run). Group + instance, recorded pulls, the whole quest log with tags,
-- dungeon quest flags, lockouts, the computed talent grid, discovery of
-- Forever's "legacy talents" / "legacy challenges" (global name scan, C_Traits
-- systems, achievement categories) and character extras. Functions are looked
-- up by name (resolve), so anything this client lacks reports "missing".

local function fn(path) return resolve(path) end

local function simple(lines, specs)
    for _, spec in ipairs(specs) do lines[#lines + 1] = "S4 " .. describeCall(spec) end
end

local function readable(value, pattern)
    return (type(value) == "string" and value ~= "" and (not pattern or value:match(pattern))) and "readable"
        or "unreadable"
end

local function s4Group(lines)
    simple(lines, { { "IsInGroup" }, { "IsInRaid" }, { "GetNumGroupMembers" }, { "GetNumSubgroupMembers" } })
    for k = 1, 4 do
        local unit = "party" .. k
        local _, exists = call(fn("UnitExists"), unit)
        if exists then
            local _, guid = call(fn("UnitGUID"), unit)
            local _, name = call(fn("GetUnitName"), unit, true)
            -- Readability only: other players' GUIDs and names are never printed.
            lines[#lines + 1] = string.format("S4 %s: exists guid=%s name=%s", unit,
                readable(guid, "^Player%-"), readable(name))
        end
    end
end

local function s4Instance(lines)
    simple(lines, { { "GetDungeonDifficultyID" }, { "GetRaidDifficultyID" }, { "GetZoneText" },
        { "GetRealZoneText" }, { "GetSubZoneText" } })
    local status, mapId = call(fn("C_Map.GetBestMapForUnit"), "player")
    if status ~= "ok" then
        lines[#lines + 1] = "S4 map: C_Map.GetBestMapForUnit " .. status
        return
    end
    local _, info = call(fn("C_Map.GetMapInfo"), mapId)
    lines[#lines + 1] = string.format('S4 map: C_Map.GetBestMapForUnit("player") = %s -> GetMapInfo = %s',
        format(mapId, 0), format(info, 0))
    local ejStatus, ejId = call(fn("EJ_GetInstanceForMap"), mapId)
    if ejStatus ~= "ok" then
        lines[#lines + 1] = "S4 dungeon guide: EJ_GetInstanceForMap " .. ejStatus
        return
    end
    local results = { call(fn("EJ_GetInstanceInfo"), ejId) }
    local text = results[1] == "ok" and formatResults({ unpack(results, 2, table.maxn(results)) },
        table.maxn(results) - 1) or results[1]
    lines[#lines + 1] = string.format("S4 dungeon guide: EJ_GetInstanceForMap(%s) = %s -> EJ_GetInstanceInfo = %s",
        format(mapId, 0), format(ejId, 0), text)
end

local function s4Pulls(lines)
    local pulls = ns.Raid.Pulls()
    if #pulls == 0 then
        lines[#lines + 1] = "S4 pulls: none recorded"
        return
    end
    for k = math.max(1, #pulls - 4), #pulls do
        local p = pulls[k]
        lines[#lines + 1] = string.format('S4 pull %d: encounterId=%s %s difficultyId=%s groupSize=%s success=%s'
            .. ' roster=%d instanceId=%s startAt=%s endAt=%s', k, tostring(p.encounterId), format(p.name, 0),
            tostring(p.difficultyId), tostring(p.groupSize), tostring(p.success),
            type(p.roster) == "table" and #p.roster or 0, tostring(p.instanceId), tostring(p.startAt),
            tostring(p.endAt))
    end
end

local function s4Quests(lines)
    local numStatus, numEntries = call(fn("C_QuestLog.GetNumQuestLogEntries"))
    if numStatus == "ok" then
        for i = 1, math.min(tonumber(numEntries) or 0, 50) do
            local _, info = call(fn("C_QuestLog.GetInfo"), i)
            if type(info) == "table" and not info.isHeader and info.questID then
                local tagStatus, tag = call(fn("C_QuestLog.GetQuestTagInfo"), info.questID)
                lines[#lines + 1] = string.format('S4 quest %s %s: level=%s suggestedGroup=%s frequency=%s'
                    .. ' isComplete=%s tag=%s', tostring(info.questID), format(info.title, 0), tostring(info.level),
                    tostring(info.suggestedGroup), tostring(info.frequency), tostring(info.isComplete),
                    tagStatus == "ok" and format(tag, 0) or tagStatus)
            end
        end
    end
    local flagged = fn("C_QuestLog.IsQuestFlaggedCompleted")
    if type(flagged) ~= "function" then
        lines[#lines + 1] = "S4 dungeon quest flags (IsQuestFlaggedCompleted): missing"
    else
        local groups = {}
        for _, d in ipairs(DUNGEON_QUESTS) do
            local parts = { d[1] }
            for _, id in ipairs(d[2]) do
                local st, done = call(flagged, id)
                parts[#parts + 1] = id .. "=" .. (st ~= "ok" and st or (done and "yes" or "no"))
            end
            groups[#groups + 1] = table.concat(parts, " ")
        end
        lines[#lines + 1] = "S4 dungeon quest flags (IsQuestFlaggedCompleted): " .. table.concat(groups, " | ")
    end
    local _, saved = call(fn("GetNumSavedInstances"))
    for i = 1, math.min(tonumber(saved) or 0, 5) do simple(lines, { { "GetSavedInstanceInfo", i } }) end
end

local function spellName(configId, entryId)
    if not entryId then return "?" end
    local defId = field(fn("C_Traits.GetEntryInfo"), "definitionID", configId, entryId)
    local spellId = defId ~= nil and field(fn("C_Traits.GetDefinitionInfo"), "spellID", defId) or nil
    if spellId == nil then return "?" end
    local nameFn = fn("C_Spell.GetSpellName") or fn("GetSpellInfo")
    local st, name = call(nameFn, spellId)
    return st == "ok" and format(name, 0) or st
end

local function s4Talents(lines)
    local _, configId = call(fn("C_ClassTalents.GetActiveConfigID"))
    local _, config = call(fn("C_Traits.GetConfigInfo"), configId)
    local grid = {}
    for _, treeId in ipairs(type(config) == "table" and config.treeIDs or {}) do
        local _, treeNodes = call(fn("C_Traits.GetTreeNodes"), treeId)
        for _, nodeId in ipairs(type(treeNodes) == "table" and treeNodes or {}) do
            local _, info = call(fn("C_Traits.GetNodeInfo"), configId, nodeId)
            info = type(info) == "table" and info or {}
            grid[#grid + 1] = { nodeId = nodeId, posX = info.posX, posY = info.posY, info = info }
        end
    end
    ns.TalentGrid.Assign(grid)
    table.sort(grid, function(a, b)
        local ka = (a.tree or 9) * 10000 + (a.row or 99) * 100 + (a.col or 99)
        local kb = (b.tree or 9) * 10000 + (b.row or 99) * 100 + (b.col or 99)
        if ka ~= kb then return ka < kb end
        return tostring(a.nodeId) < tostring(b.nodeId)
    end)
    for _, n in ipairs(grid) do
        local i = n.info
        local where = n.tree and string.format("t%d r%d c%d", n.tree, n.row, n.col) or "unplaced"
        lines[#lines + 1] = string.format("S4 talent %s: %s rank %s/%s (node %s)", where,
            spellName(configId, type(i.entryIDs) == "table" and i.entryIDs[1] or nil),
            tostring(i.activeRank or i.ranksPurchased or 0), tostring(i.maxRanks or "?"), tostring(n.nodeId))
    end
end

local DISCOVER = { "legacy", "forever", "challenge" }

local function s4Discover(lines)
    -- Names only: nothing found here is called.
    local found, namespaces = {}, {}
    for key, value in pairs(_G) do
        if type(key) == "string" then
            local lower = key:lower()
            for _, word in ipairs(DISCOVER) do
                if lower:find(word, 1, true) then
                    found[#found + 1] = key .. "(" .. type(value) .. ")"
                    if type(value) == "table" and key:match("^C_") then namespaces[#namespaces + 1] = key end
                    break
                end
            end
        end
    end
    table.sort(found)
    if #found > 80 then found[81] = "... " .. (#found - 80) .. " more"; for k = #found, 82, -1 do found[k] = nil end end
    lines[#lines + 1] = "S4 globals matching legacy|forever|challenge: " .. table.concat(found, ", ")
    table.sort(namespaces)
    for _, name in ipairs(namespaces) do
        local fns = {}
        for k, v in pairs(_G[name]) do
            if type(v) == "function" then fns[#fns + 1] = tostring(k) end
        end
        table.sort(fns)
        lines[#lines + 1] = string.format("S4 %s functions: %s", name, table.concat(fns, ", "))
    end

    -- Extra talent systems (professions / skyriding live in their own C_Traits
    -- systems on the modern client; legacy talents may too).
    local bySystem = fn("C_Traits.GetConfigIDBySystemID")
    if type(bySystem) ~= "function" then
        lines[#lines + 1] = "S4 trait systems: C_Traits.GetConfigIDBySystemID missing"
    else
        local any = false
        for systemId = 1, 300 do
            local _, configId = call(bySystem, systemId)
            if type(configId) == "number" and configId > 0 then
                any = true
                local _, info = call(fn("C_Traits.GetConfigInfo"), configId)
                local trees = {}
                for _, treeId in ipairs(type(info) == "table" and type(info.treeIDs) == "table" and info.treeIDs or {}) do
                    local _, nodes = call(fn("C_Traits.GetTreeNodes"), treeId)
                    local currency = { call(fn("C_Traits.GetTreeCurrencyInfo"), configId, treeId, false) }
                    trees[#trees + 1] = string.format("%s (%d nodes%s)", tostring(treeId),
                        type(nodes) == "table" and #nodes or 0,
                        currency[1] == "ok" and (", currency " .. format(currency[2], 0)) or "")
                end
                lines[#lines + 1] = string.format("S4 trait system %d: config %d %s trees %s", systemId, configId,
                    format(info, 1), table.concat(trees, ", "))
            end
        end
        if not any then lines[#lines + 1] = "S4 trait systems: none of 1-300 has a config" end
    end

    -- Achievements ("legacy challenges" are achievement-like).
    simple(lines, { { "GetTotalAchievementPoints" }, { "GetNumCompletedAchievements" } })
    local catStatus, cats = call(fn("GetCategoryList"))
    if catStatus ~= "ok" or type(cats) ~= "table" then
        lines[#lines + 1] = "S4 achievement categories: GetCategoryList " .. (catStatus == "ok" and "nil" or catStatus)
        return
    end
    local listed, detail = {}, {}
    for k, id in ipairs(cats) do
        local _, name = call(fn("GetCategoryInfo"), id)
        if k <= 150 then listed[#listed + 1] = tostring(id) .. " " .. format(name, 0) end
        local lower = type(name) == "string" and name:lower() or ""
        for _, word in ipairs(DISCOVER) do
            if lower:find(word, 1, true) then detail[#detail + 1] = { id = id, name = name } break end
        end
    end
    lines[#lines + 1] = "S4 achievement categories: " .. table.concat(listed, ", ")
    for _, c in ipairs(detail) do
        local counts = { call(fn("GetCategoryNumAchievements"), c.id) }
        lines[#lines + 1] = string.format("S4 achievement category %s %s: GetCategoryNumAchievements = %s",
            tostring(c.id), format(c.name, 0), counts[1] == "ok"
                and formatResults({ unpack(counts, 2, table.maxn(counts)) }, table.maxn(counts) - 1) or counts[1])
        for i = 1, math.min(tonumber(counts[2]) or 0, 10) do
            local st, id, name, points, completed, _, _, _, description = call(fn("GetAchievementInfo"), c.id, i)
            if st == "ok" and id then
                lines[#lines + 1] = string.format("S4 achievement %s %s points=%s completed=%s description=%s",
                    tostring(id), format(name, 0), tostring(points), tostring(completed), format(description, 0))
            end
        end
    end
end

local function s4Character(lines)
    simple(lines, { { "GetAverageItemLevel" }, { "UnitXP", "player" }, { "UnitXPMax", "player" },
        { "GetXPExhaustion" }, { "GetProfessions" }, { "GetNumSkillLines" } })
    local _, n = call(fn("GetNumSkillLines"))
    for i = 1, math.min(tonumber(n) or 0, 40) do simple(lines, { { "GetSkillLineInfo", i } }) end
end

local function s4Lines(lines)
    s4Group(lines)
    s4Instance(lines)
    s4Pulls(lines)
    s4Quests(lines)
    s4Talents(lines)
    s4Discover(lines)
    s4Character(lines)
end

-- ---------------------------------------------------------------------------
-- "S5": discovery for a second addon (operator 2026-10-13: mail bag items worth
-- more on the auction house, or disenchanted, to a bank alt). Price-source
-- addons and what they expose, a valuation of the bags, and the mail, auction,
-- name auto-complete, bag-frame and gamepad-binding APIs. Read-only: nothing is
-- mailed, listed, bound or auto-completed, and no player name is printed.

local S5_ADDONS = { "Auctionator", "Disenchantry", "TradeSkillMaster", "Postal", "ForeverMail", "ConsolePort",
    "Bagnon", "Baganator", "AdiBags", "ArkInventory" }
local S5_CALLER = "LedgerLink"
local S5_MAX_ITEMS = 40
local PAD_KEYS = { "PAD1", "PAD2", "PAD3", "PAD4", "PAD5", "PAD6", "PADDUP", "PADDRIGHT", "PADDDOWN", "PADDLEFT",
    "PADLSTICK", "PADRSTICK", "PADLSHOULDER", "PADRSHOULDER", "PADLTRIGGER", "PADRTRIGGER", "PADFORWARD",
    "PADBACK", "PADSYSTEM", "PADSOCIAL" }

-- Sorted "name(type)" list of a table's keys, capped.
local function keysOf(t, cap, onlyFunctions)
    local out = {}
    for k, v in pairs(t) do
        if not onlyFunctions or type(v) == "function" then
            out[#out + 1] = onlyFunctions and tostring(k) or (tostring(k) .. "(" .. type(v) .. ")")
        end
    end
    table.sort(out)
    local total = #out
    if total > cap then
        for k = total, cap + 1, -1 do out[k] = nil end
        out[#out + 1] = "... " .. (total - cap) .. " more"
    end
    return table.concat(out, ", "), total
end

-- Global names containing any of `words` (case-insensitive), names only.
local function globalsMatching(words, cap, onlyFunctions)
    local found = {}
    for key, value in pairs(_G) do
        if type(key) == "string" and (not onlyFunctions or type(value) == "function") then
            local lower = key:lower()
            for _, word in ipairs(words) do
                if lower:find(word, 1, true) then found[key] = value break end
            end
        end
    end
    return keysOf(found, cap, onlyFunctions)
end

local function s5Addons(lines)
    local isLoaded = fn("C_AddOns.IsAddOnLoaded") or fn("IsAddOnLoaded")
    local metadata = fn("C_AddOns.GetAddOnMetadata") or fn("GetAddOnMetadata")
    for _, name in ipairs(S5_ADDONS) do
        local _, loaded = call(isLoaded, name)
        local _, version = call(metadata, name, "Version")
        local _, sv = call(metadata, name, "SavedVariables")
        local _, svChar = call(metadata, name, "SavedVariablesPerCharacter")
        lines[#lines + 1] = string.format("S5 addon %s: loaded=%s version=%s SavedVariables=%s PerCharacter=%s",
            name, tostring(loaded), format(version, 0), format(sv, 0), format(svChar, 0))
        -- Top-level keys of each saved table: where the addon keeps its prices.
        for _, names in ipairs({ sv, svChar }) do
            for svName in (type(names) == "string" and names or ""):gmatch("[%w_]+") do
                local t = rawget(_G, svName)
                lines[#lines + 1] = type(t) == "table"
                    and string.format("S5 %s saved %s keys: %s", name, svName, (keysOf(t, 30)))
                    or string.format("S5 %s saved %s = %s", name, svName, type(t))
            end
        end
    end
    for _, path in ipairs({ "Auctionator.API.v1", "TSM_API" }) do
        local t = resolve(path)
        lines[#lines + 1] = "S5 " .. path .. " functions: " .. (type(t) == "table" and keysOf(t, 60, true) or "missing")
    end
    -- Disenchantry documents no API: find what it leaves in _G (names only, never called).
    lines[#lines + 1] = "S5 globals matching disenchant|enchantry: " .. globalsMatching({ "disenchant", "enchantry" }, 40)
    for key, value in pairs(_G) do
        if type(key) == "string" and type(value) == "table" and key:lower():find("enchantry", 1, true) then
            lines[#lines + 1] = string.format("S5 %s keys: %s", key, (keysOf(value, 40)))
        end
    end
    local slash = type(SlashCmdList) == "table" and SlashCmdList or {}
    local cmds = {}
    for k in pairs(slash) do
        if tostring(k):lower():find("enchant", 1, true) then cmds[#cmds + 1] = tostring(k) end
    end
    table.sort(cmds)
    lines[#lines + 1] = "S5 slash commands matching enchant: " .. table.concat(cmds, ", ")
end

-- Hyperlink text "[Linen Cloth]" -> "Linen Cloth".
local function linkName(link)
    return type(link) == "string" and link:match("%[(.-)%]") or tostring(link)
end

local function price(path, ...)
    local status, value = call(fn(path), ...)
    if status == "missing" then return "missing" end
    if status == "error" then return "error: " .. tostring(value):sub(1, 120) end
    return tostring(value)
end

local function s5Item(lines, bag, slot, info)
    local link = info.hyperlink
    local itemInfo = { call(fn("C_Item.GetItemInfo") or fn("GetItemInfo"), link) }
    local instant = { call(fn("C_Item.GetItemInfoInstant") or fn("GetItemInfoInstant"), link) }
    local _, quest = call(fn("C_Container.GetContainerItemQuestInfo"), bag, slot)
    quest = type(quest) == "table" and quest or {}
    local tsmStatus, tsmString = call(fn("TSM_API.ToItemString"), link)
    -- Commodity (stackable, priced per unit on the modern AH) or item; needs an ItemLocation.
    local commodity = "missing"
    local locStatus, location = call(fn("ItemLocation.CreateFromBagAndSlot"), resolve("ItemLocation"), bag, slot)
    if locStatus == "ok" and location ~= nil then
        commodity = price("C_AuctionHouse.GetItemCommodityStatus", location)
    elseif locStatus ~= "missing" then
        commodity = "no ItemLocation"
    end
    lines[#lines + 1] = string.format('S5 item %d/%d id=%s %q x%s quality=%s bound=%s noValue=%s locked=%s'
        .. ' quest=%s class=%s/%s equip=%s sell=%s ah=%s ahAge=%s ahExact=%s de=%s commodity=%s tsmMarket=%s',
        bag, slot, tostring(info.itemID), linkName(link), tostring(info.stackCount), tostring(info.quality),
        tostring(info.isBound), tostring(info.hasNoValue), tostring(info.isLocked),
        tostring(quest.isQuestItem), tostring(instant[7]), tostring(instant[8]), format(instant[5], 0),
        itemInfo[1] == "ok" and tostring(itemInfo[12]) or itemInfo[1],
        price("Auctionator.API.v1.GetAuctionPriceByItemLink", S5_CALLER, link),
        price("Auctionator.API.v1.GetAuctionAgeByItemLink", S5_CALLER, link),
        price("Auctionator.API.v1.IsAuctionDataExactByItemLink", S5_CALLER, link),
        price("Auctionator.API.v1.GetDisenchantPriceByItemLink", S5_CALLER, link),
        commodity,
        tsmStatus == "ok" and price("TSM_API.GetCustomPriceValue", "DBMarket", tsmString) or tsmStatus)
end

local function s5Bags(lines)
    local numSlots = fn("C_Container.GetContainerNumSlots") or fn("GetContainerNumSlots")
    local itemInfo = fn("C_Container.GetContainerItemInfo")
    local lastBag = tonumber(resolve("NUM_BAG_SLOTS")) or 4
    lines[#lines + 1] = string.format("S5 bags: NUM_BAG_SLOTS=%s C_Container.GetContainerItemInfo=%s",
        tostring(resolve("NUM_BAG_SLOTS")), type(itemInfo))
    local shown, keysShown = 0, false
    for bag = 0, lastBag do
        local _, slots = call(numSlots, bag)
        local _, free = call(fn("C_Container.GetContainerNumFreeSlots") or fn("GetContainerNumFreeSlots"), bag)
        lines[#lines + 1] = string.format("S5 bag %d: %s slots, %s free", bag, tostring(slots), tostring(free))
        for slot = 1, tonumber(slots) or 0 do
            local _, info = call(itemInfo, bag, slot)
            if type(info) == "table" then
                if not keysShown then
                    keysShown = true
                    lines[#lines + 1] = "S5 GetContainerItemInfo fields: " .. (keysOf(info, 40))
                end
                shown = shown + 1
                if shown <= S5_MAX_ITEMS then s5Item(lines, bag, slot, info) end
            end
        end
    end
    if shown > S5_MAX_ITEMS then lines[#lines + 1] = string.format("S5 items: %d more not listed", shown - S5_MAX_ITEMS) end
end

local S5_PRESENCE = {
    -- bag frames (slot-lock overlays) and sorting (slots that move)
    "ContainerFrame1", "ContainerFrame1Item1", "ContainerFrameCombinedBags", "C_Container.SortBags",
    "C_Container.GetSortBagsRightToLeft", "C_Container.UseContainerItem", "C_Container.PickupContainerItem",
    -- mail
    "MailFrame", "SendMailFrame", "SendMailNameEditBox", "SendMailMailButton", "MailFrameTab2", "SendMail",
    "ClickSendMailItemButton", "GetSendMailItem", "GetSendMailItemLink", "GetSendMailPrice", "SetSendMailMoney",
    "ClearSendMail", "GetInboxNumItems", "C_Mail", "ATTACHMENTS_MAX_SEND", "ATTACHMENTS_MAX_RECEIVE",
    -- auction house
    "AuctionFrame", "AuctionHouseFrame", "C_AuctionHouse", "QueryAuctionItems", "GetAuctionItemInfo",
    "CalculateAuctionDeposit", "GetAuctionDeposit", "GetAuctionSellItemInfo", "PostAuction",
    -- settings panel + name auto-complete
    "Settings", "Settings.RegisterCanvasLayoutCategory", "InterfaceOptions_AddCategory", "GetAutoCompleteResults",
    "AutoCompleteEditBox_SetAutoCompleteSource", "AutoComplete_UpdateResults", "EditBox_HandleTabbing",
    -- gamepad
    "C_GamePad", "SetOverrideBindingClick", "SetOverrideBinding", "ClearOverrideBindings", "GetBindingAction",
    "ConsolePort",
}

local function s5Apis(lines)
    for _, path in ipairs(S5_PRESENCE) do
        local v = resolve(path)
        local shown = (type(v) == "number" or type(v) == "string") and (type(v) .. " " .. format(v, 0)) or type(v)
        lines[#lines + 1] = "S5 " .. path .. " = " .. (v == nil and "missing" or shown)
    end
end

local function s5State(lines)
    for _, frameName in ipairs({ "MailFrame", "SendMailFrame", "AuctionFrame", "AuctionHouseFrame" }) do
        local frame = rawget(_G, frameName)
        if type(frame) == "table" and type(frame.IsShown) == "function" then
            local _, shown = call(frame.IsShown, frame)
            lines[#lines + 1] = string.format("S5 %s shown = %s", frameName, tostring(shown))
        end
    end
    for _, spec in ipairs({ { "GetSendMailPrice" }, { "GetInboxNumItems" }, { "GetCVar", "GamePadEnable" },
        { "C_GamePad.IsEnabled" }, { "C_GamePad.GetActiveDeviceID" } }) do
        lines[#lines + 1] = "S5 " .. describeCall(spec)
    end
    -- What the mail name box auto-completes from (flags only; nothing is looked up).
    local box = rawget(_G, "SendMailNameEditBox")
    lines[#lines + 1] = "S5 SendMailNameEditBox.autoCompleteParams = "
        .. format(type(box) == "table" and rawget(box, "autoCompleteParams") or nil, 0)
    local flags = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and k:match("^AUTOCOMPLETE_") and type(v) == "number" then flags[#flags + 1] = k .. "=" .. v end
    end
    table.sort(flags)
    lines[#lines + 1] = "S5 AUTOCOMPLETE_ constants: " .. table.concat(flags, ", ")
    local binding = fn("GetBindingAction")
    local pads = {}
    for _, key in ipairs(PAD_KEYS) do
        local status, action = call(binding, key)
        pads[#pads + 1] = key .. "=" .. (status ~= "ok" and status or (action ~= nil and action ~= "" and action or "-"))
    end
    lines[#lines + 1] = "S5 gamepad bindings: " .. table.concat(pads, ", ")
end

local function s5Discover(lines)
    for _, path in ipairs({ "C_Mail", "C_AuctionHouse", "C_GamePad" }) do
        local t = resolve(path)
        if type(t) == "table" then lines[#lines + 1] = "S5 " .. path .. " functions: " .. keysOf(t, 80, true) end
    end
    lines[#lines + 1] = "S5 global functions matching mail: " .. globalsMatching({ "mail" }, 80, true)
    lines[#lines + 1] = "S5 global functions matching auction: " .. globalsMatching({ "auction" }, 80, true)
    lines[#lines + 1] = "S5 globals matching autocomplete: " .. globalsMatching({ "autocomplete" }, 40)
end

local function s5Lines(lines)
    s5Addons(lines)
    s5Bags(lines)
    s5Apis(lines)
    s5State(lines)
    s5Discover(lines)
end

-- ---------------------------------------------------------------------------
-- "S6": Forever's built-in gamepad UI. The first report (v1.3.1, 2026-10-13)
-- showed it is Blizzard's "smart navigation": the mail frames carry
-- FocusGamepad / InitializeGamepad / LockInFocus methods, a gamepadFooter table
-- plus a "...FooterinputLegend" frame (the "Cross Select / Square Open All"
-- bar) and a smartNavigationFocusKey; C_Navigation, InputPromptMixin,
-- InputPromptLegends and PromptedBindingFooterMixin exist. These lines look
-- inside them, so a second addon can add its own footer action (Triangle) and
-- join the window cycle. Reads tables and names only: nothing is called except
-- read-only getters (GetName, GetChildren, GetCVar, the console command list).

local S6_FRAMES = { "MailFrame", "InboxFrame", "SendMailFrame" }
local S6_FOOTERS = { "InboxFrame", "SendMailFrame", "OpenMailFrame" }
local S6_LEGENDS = { "InboxFrame.InboxFooterinputLegend", "SendMailFrame.SendMailFooterinputLegend",
    "OpenMailFrame.OpenMailFooterinputLegend" }
local S6_MIXIN_WORDS = { "gamepad", "smartnav", "navigation", "focus", "legend", "inputprompt", "prompt", "footer",
    "jumphint" }
-- Methods the mail frames' gamepad support exposes: a mixin carrying any of them is the one to reuse.
local S6_GAMEPAD_METHODS = { "FocusGamepad", "InitializeGamepad", "SetupGamepad", "StartFocus", "LockInFocus",
    "UnfocusGamepad", "RefreshFocus", "GetFocusFrameRoot" }
local S6_MAX_MIXINS = 40
local S6_MAX_LINE = 3000

local function frameName(f)
    if type(f) ~= "table" then return tostring(f) end
    local status, name = call(f.GetName, f)
    if status == "ok" and name then return tostring(name) end
    local dStatus, debugName = call(f.GetDebugName, f)
    return (dStatus == "ok" and debugName) and ("(" .. tostring(debugName) .. ")") or "(anonymous)"
end

-- Deep, read-only dump: frames (tables holding [0] userdata) print as <frame Name>,
-- functions as "function"; depth and length are capped.
local function dump(v, depth, maxDepth)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return t == "function" and "function" or tostring(v) end
    if rawget(v, 0) ~= nil then return "<frame " .. frameName(v) .. ">" end
    if depth >= maxDepth then return "{...}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for i, k in ipairs(keys) do
        if i > MAX_ITEMS then parts[#parts + 1] = "..." break end
        parts[#parts + 1] = tostring(k) .. " = " .. dump(v[k], depth + 1, maxDepth)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function capped(text)
    if #text <= S6_MAX_LINE then return text end
    return text:sub(1, S6_MAX_LINE) .. " ... (" .. (#text - S6_MAX_LINE) .. " more chars)"
end

-- A frame's own Lua fields (template keys, mixin methods) and its child frames.
local function s6Frame(lines, path)
    local f = resolve(path)
    if type(f) ~= "table" then
        lines[#lines + 1] = "S6 frame " .. path .. " = " .. (f == nil and "missing" or type(f))
        return
    end
    local own = {}
    for k, v in pairs(f) do
        if k ~= 0 then own[tostring(k)] = v end
    end
    lines[#lines + 1] = string.format("S6 frame %s fields: %s", path, (keysOf(own, 80)))
    local children = { call(f.GetChildren, f) }
    if children[1] == "ok" then
        local names = {}
        for i = 2, table.maxn(children) do names[#names + 1] = frameName(children[i]) end
        lines[#lines + 1] = string.format("S6 frame %s children (%d): %s", path, #names, table.concat(names, ", "))
    end
end

local function s6Footers(lines)
    for _, name in ipairs(S6_FOOTERS) do
        local f = rawget(_G, name)
        local footer = type(f) == "table" and rawget(f, "gamepadFooter") or nil
        lines[#lines + 1] = capped(string.format("S6 %s.gamepadFooter = %s", name, dump(footer, 0, 4)))
        lines[#lines + 1] = string.format("S6 %s.smartNavigationFocusKey = %s", name,
            format(type(f) == "table" and rawget(f, "smartNavigationFocusKey") or nil, 0))
    end
    for _, path in ipairs(S6_LEGENDS) do s6Frame(lines, path) end
    local mail = rawget(_G, "MailFrame")
    if type(mail) == "table" then
        for _, key in ipairs({ "isFocused", "hasDoneInitialFocus", "selectedTab" }) do
            lines[#lines + 1] = string.format("S6 MailFrame.%s = %s", key, format(rawget(mail, key), 0))
        end
        for _, key in ipairs({ "FocusJumpHint", "LeftJumpHint", "RightJumpHint", "TabIndicators" }) do
            lines[#lines + 1] = capped(string.format("S6 MailFrame.%s = %s", key, dump(rawget(mail, key), 0, 1)))
        end
    end
end

local function hasAny(t, methods)
    for _, m in ipairs(methods) do
        if type(rawget(t, m)) == "function" then return true end
    end
    return false
end

local function s6Mixins(lines)
    local names = {}
    for key, value in pairs(_G) do
        if type(key) == "string" and type(value) == "table" and key:match("Mixin$") then
            local lower, match = key:lower(), hasAny(value, S6_GAMEPAD_METHODS)
            for _, word in ipairs(S6_MIXIN_WORDS) do
                if match then break end
                match = lower:find(word, 1, true) ~= nil
            end
            if match then names[#names + 1] = key end
        end
    end
    table.sort(names)
    lines[#lines + 1] = string.format("S6 gamepad-related mixins (%d): %s", #names, table.concat(names, ", "))
    for i, key in ipairs(names) do
        if i > S6_MAX_MIXINS then
            lines[#lines + 1] = string.format("S6 mixins: %d more not listed", #names - S6_MAX_MIXINS)
            break
        end
        lines[#lines + 1] = string.format("S6 mixin %s: %s", key, (keysOf(_G[key], 60, true)))
    end
end

local function s6Namespaces(lines)
    local found = {}
    for key, value in pairs(_G) do
        if type(key) == "string" and key:match("^C_") and type(value) == "table" then
            local lower = key:lower()
            for _, word in ipairs({ "nav", "focus", "input", "prompt", "gamepad", "legend", "cursor" }) do
                if lower:find(word, 1, true) then found[#found + 1] = key break end
            end
        end
    end
    table.sort(found)
    for _, key in ipairs(found) do
        lines[#lines + 1] = string.format("S6 %s functions: %s", key, (keysOf(_G[key], 80, true)))
    end
    lines[#lines + 1] = capped("S6 InputPromptLegends = " .. dump(rawget(_G, "InputPromptLegends"), 0, 3))
    lines[#lines + 1] = "S6 globals matching smartnav|legend: " .. globalsMatching({ "smartnav", "legend" }, 60)
end

local function s6CVars(lines)
    local status, commands = call(fn("C_Console.GetAllCommands") or fn("ConsoleGetAllCommands"))
    if status ~= "ok" or type(commands) ~= "table" then
        lines[#lines + 1] = "S6 CVars: GetAllCommands " .. (status == "ok" and "nil" or status)
        return
    end
    local out = {}
    for _, c in ipairs(commands) do
        local name = type(c) == "table" and c.command
        local lower = type(name) == "string" and name:lower() or ""
        if lower:find("gamepad", 1, true) or lower:find("cursor", 1, true) or lower:find("smartnav", 1, true) then
            local _, value = call(fn("GetCVar"), name)
            out[#out + 1] = name .. "=" .. tostring(value)
        end
    end
    table.sort(out)
    lines[#lines + 1] = capped(string.format("S6 CVars matching gamepad|cursor|smartnav (%d): %s", #out,
        table.concat(out, ", ")))
end

local function s6Lines(lines)
    for _, name in ipairs(S6_FRAMES) do s6Frame(lines, name) end
    s6Footers(lines)
    s6Mixins(lines)
    s6Namespaces(lines)
    s6CVars(lines)
end

-- ---------------------------------------------------------------------------
-- "S7": the gamepad "More" menu on a bag slot (operator 2026-10-13: Triangle on
-- an item opens a menu; a second addon wants a "Lock slot" entry in it). Static
-- part: context-action labels, context/menu mixins and the Menu / MenuUtil API.
-- Recorder: a post-hook (hooksecurefunc) on the menu manager's open functions
-- that only notes which menu opened, its tag and its entry texts, so the probe
-- can name the menu the player just opened. It never changes a menu.

local S7_MAX = 10
local menuOpens = {}
Probe.menuOpens = menuOpens

local function entryTexts(description)
    local texts = {}
    local elements = type(description) == "table" and rawget(description, "elementDescriptions") or nil
    for _, e in ipairs(type(elements) == "table" and elements or {}) do
        local text = type(e) == "table" and rawget(e, "text") or nil
        texts[#texts + 1] = type(text) == "string" and text or "?"
    end
    return table.concat(texts, " | ")
end

local function recordMenu(method, owner, description)
    local tag = type(description) == "table" and rawget(description, "tag") or nil
    if tag == nil and type(description) == "table" then
        local status, value = call(description.GetTag, description)
        if status == "ok" then tag = value end
    end
    menuOpens[#menuOpens + 1] = {
        method = method, owner = frameName(owner), tag = tag, entries = entryTexts(description),
        fields = type(description) == "table" and (keysOf(description, 30)) or type(description),
    }
    while #menuOpens > S7_MAX do table.remove(menuOpens, 1) end
end

-- Installed once at load; every step is guarded so a client without the
-- modern menu API just records nothing.
function Probe.InstallMenuWatch()
    local hook = rawget(_G, "hooksecurefunc")
    if type(hook) ~= "function" then return end
    local _, manager = call(fn("Menu.GetManager"))
    if type(manager) == "table" then
        for _, method in ipairs({ "OpenMenu", "OpenContextMenu" }) do
            if type(manager[method]) == "function" then
                pcall(hook, manager, method, function(_, owner, description)
                    pcall(recordMenu, "Menu:" .. method, owner, description)
                end)
            end
        end
    end
    local menuUtil = rawget(_G, "MenuUtil")
    if type(menuUtil) == "table" and type(menuUtil.CreateContextMenu) == "function" then
        pcall(hook, menuUtil, "CreateContextMenu", function(owner)
            pcall(recordMenu, "MenuUtil.CreateContextMenu", owner, nil)
        end)
    end
end

local function s7Lines(lines)
    local labels = {}
    for key, value in pairs(_G) do
        if type(key) == "string" and key:match("^CONTEXT_ACTION") and type(value) == "string" then
            labels[#labels + 1] = key .. "=" .. format(value, 0)
        end
    end
    table.sort(labels)
    lines[#lines + 1] = capped(string.format("S7 context action labels (%d): %s", #labels, table.concat(labels, ", ")))
    lines[#lines + 1] = "S7 globals matching contextaction|context_action|contextmenu|itemaction: "
        .. globalsMatching({ "contextaction", "context_action", "contextmenu", "itemaction" }, 60)
    local mixins = {}
    for key, value in pairs(_G) do
        if type(key) == "string" and type(value) == "table" and key:match("Mixin$") then
            local lower = key:lower()
            if lower:find("context", 1, true) or lower:find("menu", 1, true) then mixins[#mixins + 1] = key end
        end
    end
    table.sort(mixins)
    lines[#lines + 1] = string.format("S7 context/menu mixins (%d): %s", #mixins, table.concat(mixins, ", "))
    for i, key in ipairs(mixins) do
        if i > S6_MAX_MIXINS then break end
        if key:lower():find("context", 1, true) then
            lines[#lines + 1] = string.format("S7 mixin %s: %s", key, (keysOf(_G[key], 60, true)))
        end
    end
    for _, path in ipairs({ "Menu", "MenuUtil" }) do
        local t = resolve(path)
        lines[#lines + 1] = "S7 " .. path .. " functions: " .. (type(t) == "table" and keysOf(t, 60, true) or "missing")
    end
    local _, manager = call(fn("Menu.GetManager"))
    lines[#lines + 1] = "S7 Menu.GetManager() fields: " .. (type(manager) == "table" and keysOf(manager, 60) or tostring(manager))
    if #menuOpens == 0 then
        lines[#lines + 1] = "S7 menus opened this session: none recorded (press Triangle on a bag item, open its menu, then /rl probe)"
    end
    for i, m in ipairs(menuOpens) do
        lines[#lines + 1] = capped(string.format("S7 menu opened %d: %s owner=%s tag=%s entries: %s; fields: %s", i,
            m.method, m.owner, format(m.tag, 0), m.entries, m.fields))
    end
end

-- ---------------------------------------------------------------------------
-- "S8": auction house deposits (operator 2026-10-13: "the deposit should come
-- from AH data"). Run with the auction house open. For each tradeable bag
-- stack, the deposit C_AuctionHouse would charge for 12h / 24h / 48h, for the
-- whole stack and for one unit, so a second addon can learn deposit as a share
-- of vendor price. Calculations only: nothing is posted. Signatures from
-- Blizzard_APIDocumentationGenerated/AuctionHouseDocumentation.lua (Forever):
-- CalculateItemDeposit(itemLocation, duration, quantity),
-- CalculateCommodityDeposit(itemID, duration, quantity); duration 1-3.

local S8_DURATIONS = { "12h", "24h", "48h" }
local S8_COMMODITY = 2 -- C_AuctionHouse.GetItemCommodityStatus: 1 item, 2 commodity (S5 report 2026-10-13)

local function s8Deposits(itemId, location, commodity, quantity)
    local parts = {}
    for d, label in ipairs(S8_DURATIONS) do
        local value
        if commodity then
            value = price("C_AuctionHouse.CalculateCommodityDeposit", itemId, d, quantity)
        else
            value = price("C_AuctionHouse.CalculateItemDeposit", location, d, quantity)
        end
        parts[#parts + 1] = label .. "=" .. value
    end
    return table.concat(parts, " ")
end

local function s8Lines(lines)
    local frame = rawget(_G, "AuctionHouseFrame")
    local shownStatus, shown = call(type(frame) == "table" and frame.IsShown, frame)
    lines[#lines + 1] = "S8 AuctionHouseFrame shown = " .. (shownStatus == "ok" and tostring(shown) or shownStatus)
        .. " (deposits need the auction house open)"
    local numSlots = fn("C_Container.GetContainerNumSlots")
    local itemInfo = fn("C_Container.GetContainerItemInfo")
    local listed = 0
    for bag = 0, tonumber(resolve("NUM_BAG_SLOTS")) or 4 do
        local _, slots = call(numSlots, bag)
        for slot = 1, tonumber(slots) or 0 do
            local _, info = call(itemInfo, bag, slot)
            local _, quest = call(fn("C_Container.GetContainerItemQuestInfo"), bag, slot)
            local isQuest = type(quest) == "table" and quest.isQuestItem
            if type(info) == "table" and not info.isBound and not isQuest and listed < S5_MAX_ITEMS then
                listed = listed + 1
                local _, location = call(fn("ItemLocation.CreateFromBagAndSlot"), resolve("ItemLocation"), bag, slot)
                local _, status = call(fn("C_AuctionHouse.GetItemCommodityStatus"), location)
                local commodity = status == S8_COMMODITY
                local itemInfoResults = { call(fn("C_Item.GetItemInfo") or fn("GetItemInfo"), info.hyperlink) }
                local count = tonumber(info.stackCount) or 1
                lines[#lines + 1] = string.format('S8 deposit %d/%d id=%s %q %s sell=%s x%d: stack %s | one %s',
                    bag, slot, tostring(info.itemID), linkName(info.hyperlink), commodity and "commodity" or "item",
                    itemInfoResults[1] == "ok" and tostring(itemInfoResults[12]) or "?", count,
                    s8Deposits(info.itemID, location, commodity, count), s8Deposits(info.itemID, location, commodity, 1))
            end
        end
    end
    if listed == 0 then lines[#lines + 1] = "S8 deposits: no tradeable bag items" end
end

local function s3Lines(lines)
    local sStatus, sex = call(UnitSex, "player")
    lines[#lines + 1] = 'S3 UnitSex("player") = ' .. (sStatus == "ok" and format(sex, 0) or sStatus)
    s3Talents(lines)
    local completed = s3Quests(lines)
    s3DungeonQuests(lines, completed)
    s3Size(lines, completed)
    s4Lines(lines)
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
    s5Lines(lines)
    s6Lines(lines)
    s7Lines(lines)
    s8Lines(lines)
    return table.concat(lines, "\n")
end

Probe.InstallMenuWatch()

Probe.FOOTER = "Click the text, Ctrl+C, then paste this report to the addon developer (not into Raid Ledger)"

function Probe.Show()
    ns.ExportFrame.Show("beta probe", Probe.Report(), Probe.FOOTER)
end
