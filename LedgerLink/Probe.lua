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
    return table.concat(lines, "\n")
end

Probe.FOOTER = "Click the text, Ctrl+C, then paste this report to the addon developer (not into Raid Ledger)"

function Probe.Show()
    ns.ExportFrame.Show("beta probe", Probe.Report(), Probe.FOOTER)
end
