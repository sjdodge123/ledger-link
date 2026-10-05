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
    return table.concat(lines, "\n")
end

Probe.FOOTER = "Click the text, Ctrl+C, then paste this report to the addon developer (not into Raid Ledger)"

function Probe.Show()
    ns.ExportFrame.Show("beta probe", Probe.Report(), Probe.FOOTER)
end
