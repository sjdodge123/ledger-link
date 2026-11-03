-- /rl dev (Raid Ledger ROK-2072): a fixed diagnostic snapshot, written into
-- SavedVariables on every save (PLAYER_LOGOUT fires on /reload, logout and
-- exit) so the Raid Ledger Companion can serve it over its LAN dev bridge.
-- Off by default. While off, LedgerLinkDB carries no `dev` key at all.
--
--   LedgerLinkDB.dev = {
--       v = 1, enabledAt = <unix s>,
--       snapshots  = { [<player guid>] = "<ledgerlink-snapshot JSON>" },
--       capturedAt = { [<player guid>] = <unix s> }, -- drives the oldest-first trim
--   }
--
-- The format is Raid Ledger's (dev-bridge/v1 `ledgerlink-snapshot`). The JSON
-- never holds a GUID, a character/realm/guild name: name-bearing calls are
-- reported as presence only, and any GUID left in a text line is scrubbed.
local _, ns = ...

local Json = ns.Json
local Probe = ns.Probe
local DevSnapshot = {}
ns.DevSnapshot = DevSnapshot

DevSnapshot.MAX_CHARACTERS = 10
DevSnapshot.SECTIONS = { "S3", "S9" }
DevSnapshot.TIME_BUDGET_MS = 50
DevSnapshot.MAX_BYTES = 49152      -- whole snapshot
DevSnapshot.HEAD_MAX_BYTES = 4096  -- snapshot minus calls/apis/sections
DevSnapshot.ITEM_MAX_BYTES = 3072  -- one calls[] / apis[] / sections[] item
local MAX_LINES, MAX_LINE_BYTES, MAX_RULES, MAX_ENTRIES = 40, 256, 64, 40

-- Presence-only list (with Probe.PRESENCE): every API the addon calls outside
-- Probe.lua, the S3/S9 sources, and the 1.60.1 removals. spec/dev_snapshot_spec
-- fails when the stub defines an API that is not listed here.
DevSnapshot.WATCHED = {
    "GetBuildInfo", "GetCurrentRegion", "GetCurrentRegionName", "GetLocale", "GetRealmName", "GetServerTime",
    "GetNormalizedRealmName", "GetUnitName", "UnitName", "UnitFullName", "UnitGUID", "UnitClass", "UnitRace",
    "UnitLevel", "UnitFactionGroup", "UnitSex", "GetGuildInfo", "IsInGuild", "InCombatLockdown", "GetCVar",
    "GetInventoryItemLink", "GetInventoryItemID", "C_Item", "C_ClassTalents", "C_ClassTalents.GetActiveConfigID",
    "C_Traits.GenerateImportString", "C_Traits.GetConfigInfo", "C_Traits.GetTreeNodes", "C_Traits.GetNodeInfo",
    "C_Traits.GetEntryInfo", "C_Traits.GetDefinitionInfo", "C_Spell", "C_Spell.GetSpellName", "GetSpellInfo",
    "C_QuestLog", "C_QuestLog.GetAllCompletedQuestIDs", "C_QuestLog.GetNumQuestLogEntries",
    "GetNumSavedInstances", "GetSavedInstanceInfo", "GetNumGuildMembers", "GetGuildRosterInfo",
    "GetGuildRosterLastOnline", "GetNumGroupMembers", "IsInRaid", "GetInstanceInfo",
    "C_EncodingUtil.DecompressString", "C_EncodingUtil.DecodeBase64", "Enum", "Enum.CompressionLevel",
    "C_GameRules", "C_GameRules.IsHardcoreActive", "C_GameRules.IsSelfFoundAllowed",
    "C_GameRules.GetForeverExperiencePreset", "C_GameRules.IsGameRuleActive", "Enum.GameRule",
    "C_SkillInfo", "C_SkillInfo.GetNumSkillLines", "C_SkillInfo.GetSkillLineInfo", "GetSkillLineInfo",
    "GetNumSkillLines", "GetProfessions", "GetProfessionInfo", "C_TradeSkillUI.GetProfessionInfoBySkillLineID",
    "C_AddOns", "C_AddOns.GetAddOnMetadata", "GetAddOnMetadata", "debugprofilestop", "CreateFrame",
    "GetCursorPosition",
}

local resolve = Probe.resolve
local FACTIONS = { Alliance = true, Horde = true, Neutral = true }

local function call(path, ...) return ns.SafeCall(resolve(path), ...) end
local function bytes(v) return #Json.encode(v) end
local function scrub(s) return (string.gsub(s, "Player%-%d+%-%x+", "<guid>")) end
local function text(s, max) return ns.Clip(scrub(tostring(s)), max) end
local function orNull(v) if v == nil then return Json.null end return v end

function DevSnapshot.Enabled()
    return type(LedgerLinkDB) == "table" and type(LedgerLinkDB.dev) == "table"
end

--- /rl dev on|off. Off removes the whole `dev` table (and every snapshot in it).
function DevSnapshot.SetEnabled(on)
    if type(LedgerLinkDB) ~= "table" then return end
    if not on then
        LedgerLinkDB.dev = nil
    elseif not DevSnapshot.Enabled() then
        LedgerLinkDB.dev = { v = 1, enabledAt = time(), snapshots = {}, capturedAt = {} }
    end
end

function DevSnapshot.Count()
    local n = 0
    if DevSnapshot.Enabled() and type(LedgerLinkDB.dev.snapshots) == "table" then
        for _ in pairs(LedgerLinkDB.dev.snapshots) do n = n + 1 end
    end
    return n
end

--- A Lua value as a JSON-safe probe value: tables at most 3 deep, ≤ 40 entries,
--- strings ≤ 512 bytes. `cut.truncated` is set when anything was dropped.
local function jsonValue(v, depth, cut)
    local kind = type(v)
    if v == nil then return Json.null end
    if kind == "boolean" then return v end
    if kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
        return v
    end
    if kind == "string" then
        local s = text(v, 512)
        if #s < #v then cut.truncated = true end
        return s
    end
    if kind ~= "table" then return "<" .. kind .. ">" end
    if depth >= 3 then cut.truncated = true return "{...}" end
    local n, keys = #v, {}
    for k in pairs(v) do keys[#keys + 1] = k end
    if #keys == n and n > 0 then
        local out = Json.array()
        for i = 1, math.min(n, MAX_ENTRIES) do out[i] = jsonValue(v[i], depth + 1, cut) end
        if n > MAX_ENTRIES then cut.truncated = true end
        return out
    end
    if #keys == 0 then return Json.array() end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for i, k in ipairs(keys) do
        if i > MAX_ENTRIES then cut.truncated = true break end
        out[text(k, 128)] = jsonValue(v[k], depth + 1, cut)
    end
    return out
end

local function client()
    local version, build, buildDate, interface = call("GetBuildInfo")
    local metadata = resolve("C_AddOns.GetAddOnMetadata") or resolve("GetAddOnMetadata")
    local toc = ns.AsId(tonumber(ns.SafeCall(metadata, ns.NAME or "LedgerLink", "Interface") or ""))
    local region = call("GetCurrentRegion")
    local iface = ns.AsId(interface)
    return {
        version = text(version or "", 32), build = text(build or "", 16), buildDate = text(buildDate or "", 32),
        interface = (iface and iface <= 9999999) and iface or 0,
        tocInterface = (toc and toc <= 9999999) and toc or Json.null,
        locale = text(call("GetLocale") or "", 8),
        region = (type(region) == "number" and region == math.floor(region)) and region or Json.null,
    }
end

local function character()
    local _, classToken = call("UnitClass", "player")
    local level = ns.AsId(call("UnitLevel", "player"))
    local faction = call("UnitFactionGroup", "player")
    return {
        class = (type(classToken) == "string" and classToken:match("^%u%u+$") and #classToken <= 16)
            and classToken or Json.null,
        level = (level and level >= 1 and level <= 100) and level or Json.null,
        faction = FACTIONS[faction] and faction or Json.null,
        inGuild = call("IsInGuild") == true,
    }
end

local function gameRule(name, value, isActive)
    if type(value) ~= "number" or value ~= value then value = text(value, 64) end
    local rule = { name = name, value = value, active = Json.null }
    local ok, active = pcall(isActive, value)
    if not ok then rule.error = text(active, 256)
    elseif type(active) == "boolean" then rule.active = active end
    return rule
end

-- D8: Enum.GameRule is discovered, never assumed.
local function ruleset()
    local isActive, members = resolve("C_GameRules.IsGameRuleActive"), resolve("Enum.GameRule")
    local rules, names = Json.array(), {}
    if type(isActive) == "function" and type(members) == "table" then
        for k in pairs(members) do
            if type(k) == "string" and k:match("^[A-Za-z_][A-Za-z0-9_]*$") and #k <= 64 then names[#names + 1] = k end
        end
        table.sort(names)
        for i = 1, math.min(#names, MAX_RULES) do rules[i] = gameRule(names[i], members[names[i]], isActive) end
    end
    local value, source = ns.Identity.Ruleset()
    return {
        isGameRuleActive = type(isActive), enumGameRule = type(members), rules = rules,
        rulesTruncated = #names > MAX_RULES, ledgerLink = { value = orNull(value), source = orNull(source) },
    }
end

local function callArgs(spec)
    if #spec < 2 then return nil end
    local args = Json.array()
    for i = 2, #spec do
        local a = spec[i]
        args[#args + 1] = type(a) == "string" and text(a, 128) or a
    end
    return args
end

-- Drop trailing entries of item[key] until the item fits ITEM_MAX_BYTES.
local function fitItem(item, key)
    while bytes(item) > DevSnapshot.ITEM_MAX_BYTES and item[key] and #item[key] > 0 do
        item[key][#item[key]] = nil
        item.truncated = true
    end
    if bytes(item) > DevSnapshot.ITEM_MAX_BYTES then item[key], item.truncated = nil, true end
    return item
end

local function callItem(spec)
    local fn = spec[1]
    local item = { fn = fn, args = callArgs(spec) }
    if Probe.NAME_BEARING[fn] then
        item.status, item.type = "presence", type(resolve(fn))
        return item
    end
    local result = Probe.CallResult(spec)
    item.status = result.status
    if result.error then item.error = text(result.error, 512) end
    if result.status == "ok" then
        local cut, values = {}, Json.array()
        for i = 1, math.min(result.n, MAX_ENTRIES) do values[i] = jsonValue(result.values[i], 0, cut) end
        item.values = values
        if result.n > MAX_ENTRIES or cut.truncated then item.truncated = true end
    end
    return fitItem(item, "values")
end

local function calls()
    local out = Json.array()
    for _, spec in ipairs(Probe.CALLS) do out[#out + 1] = callItem(spec) end
    return out
end

local function apis()
    local seen, paths = {}, {}
    for _, list in ipairs({ Probe.PRESENCE, DevSnapshot.WATCHED }) do
        for _, path in ipairs(list) do
            if not seen[path] then seen[path], paths[#paths + 1] = true, path end
        end
    end
    table.sort(paths)
    local out = Json.array()
    for i, path in ipairs(paths) do out[i] = { path = path, type = type(resolve(path)) } end
    return out
end

local function section(id)
    local raw = {}
    local ok, err = pcall(Probe.SECTION_BUILDERS[id], raw)
    local item = { id = id, status = ok and "ok" or "error", lines = Json.array() }
    if not ok then item.error = text(err, 512) end
    for i, line in ipairs(raw) do
        if i > MAX_LINES then item.truncated = true break end
        local clipped = text(line, MAX_LINE_BYTES)
        if #clipped < #scrub(tostring(line)) then item.truncated = true end
        item.lines[i] = clipped
    end
    return fitItem(item, "lines")
end

local function sections(snapshot)
    local out, start = Json.array(), ns.SafeCall(resolve("debugprofilestop"))
    for _, id in ipairs(DevSnapshot.SECTIONS) do
        local now = ns.SafeCall(resolve("debugprofilestop"))
        if type(start) == "number" and type(now) == "number" and now - start > DevSnapshot.TIME_BUDGET_MS then
            out[#out + 1] = { id = id, status = "skipped", lines = Json.array() }
            snapshot.truncated = true
        else
            out[#out + 1] = section(id)
        end
    end
    return out
end

local function headBytes(snapshot)
    local c, a, s = snapshot.calls, snapshot.apis, snapshot.sections
    snapshot.calls, snapshot.apis, snapshot.sections = nil, nil, nil
    local n = bytes(snapshot)
    snapshot.calls, snapshot.apis, snapshot.sections = c, a, s
    return n
end

-- Head ≤ 4 KiB (drop trailing game rules), whole ≤ 48 KiB (drop call values, then section lines).
local function fitSnapshot(snapshot)
    local rules = snapshot.ruleset.rules
    while headBytes(snapshot) > DevSnapshot.HEAD_MAX_BYTES and #rules > 0 do
        rules[#rules], snapshot.ruleset.rulesTruncated = nil, true
    end
    for _, list in ipairs({ { snapshot.calls, "values" }, { snapshot.sections, "lines" } }) do
        for i = #list[1], 1, -1 do
            if bytes(snapshot) <= DevSnapshot.MAX_BYTES then break end
            local item = list[1][i]
            if item[list[2]] and #item[list[2]] > 0 then
                item[list[2]] = list[2] == "lines" and Json.array() or nil
                item.truncated = true
            end
        end
    end
    for _, item in ipairs(snapshot.calls) do if item.truncated then snapshot.truncated = true end end
    for _, item in ipairs(snapshot.sections) do if item.truncated then snapshot.truncated = true end end
    if snapshot.ruleset.rulesTruncated then snapshot.truncated = true end
end

--- The snapshot as a Lua table (Json.encode gives the stored string).
function DevSnapshot.Build()
    local snapshot = {
        snapshotVersion = 1,
        addonVersion = text(ns.VERSION or "?", 64),
        capturedAt = date("!%Y-%m-%dT%H:%M:%SZ"),
        trigger = "logout",
        client = client(), character = character(), ruleset = ruleset(),
        truncated = false,
    }
    snapshot.calls = calls()
    snapshot.apis = apis()
    snapshot.sections = sections(snapshot)
    fitSnapshot(snapshot)
    return snapshot
end

local function trim(dev, keep)
    while true do
        local count, oldestKey, oldestAt = 0, nil, nil
        for guid in pairs(dev.snapshots) do
            count = count + 1
            local at = tonumber(dev.capturedAt[guid]) or 0
            if guid ~= keep and (oldestAt == nil or at < oldestAt) then oldestKey, oldestAt = guid, at end
        end
        if count <= DevSnapshot.MAX_CHARACTERS or oldestKey == nil then return end
        dev.snapshots[oldestKey], dev.capturedAt[oldestKey] = nil, nil
    end
end

--- Store `json` as this character's snapshot. Nothing without a valid player GUID.
function DevSnapshot.Store(json)
    if not DevSnapshot.Enabled() or type(json) ~= "string" or #json > DevSnapshot.MAX_BYTES then return false end
    local guid = ns.NormalizeGuid(call("UnitGUID", "player"))
    if not guid then return false end
    local dev = LedgerLinkDB.dev
    if type(dev.snapshots) ~= "table" then dev.snapshots = {} end
    if type(dev.capturedAt) ~= "table" then dev.capturedAt = {} end
    dev.snapshots[guid], dev.capturedAt[guid] = json, time()
    trim(dev, guid)
    return true
end

--- PLAYER_LOGOUT: never throws; a failure keeps the previous snapshot.
function DevSnapshot.OnLogout()
    if not DevSnapshot.Enabled() then return false end
    local ok, stored = pcall(function() return DevSnapshot.Store(Json.encode(DevSnapshot.Build())) end)
    return ok and stored == true
end

DevSnapshot.frame = CreateFrame("Frame")
DevSnapshot.frame:RegisterEvent("PLAYER_LOGOUT")
DevSnapshot.frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then DevSnapshot.OnLogout() end
end)
