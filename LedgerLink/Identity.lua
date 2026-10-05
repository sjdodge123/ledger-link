-- Who is exporting: the `client` and `who` envelope blocks.
-- Raw identity calls are stored as returned; Raid Ledger decides the name.
local _, ns = ...

local Json = ns.Json
local Identity = {}
ns.Identity = Identity

local RULESETS = { normal = true, pvp = true, roleplaying = true, hardcore = true }
local FACTIONS = { Alliance = true, Horde = true, Neutral = true }

--- Call a WoW API that may be missing or throw on a beta build.
function ns.SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local results = { pcall(fn, ...) }
    if not results[1] then return nil end
    return unpack(results, 2, table.maxn(results))
end

--- Truncate a string to `max` bytes; nil for anything that isn't a string.
function ns.Clip(s, max)
    if type(s) ~= "string" then return nil end
    if #s > max then return string.sub(s, 1, max) end
    return s
end

--- A whole number in [0, 2^31-1], or nil.
function ns.AsId(v)
    if type(v) ~= "number" or v ~= v or v < 0 or v > 2147483647 then return nil end
    return math.floor(v)
end

local function tuple(a, b)
    local first = ns.Clip(a, 100)
    local second = ns.Clip(b, 100)
    if first == nil and second == nil then return nil end
    return Json.array({ first or Json.null, second or Json.null })
end

function Identity.Client()
    local version, build, _, interface = ns.SafeCall(GetBuildInfo)
    local region = ns.SafeCall(GetCurrentRegion)
    if type(region) ~= "number" or region < 1 or region > 5 then
        return nil, "Couldn't read your region (GetCurrentRegion returned "
            .. tostring(region) .. "). Please report this."
    end
    local buildString = tostring(version or "?")
    if build then buildString = buildString .. "." .. tostring(build) end
    return {
        interface = ns.AsId(interface) or 0,
        build = ns.Clip(buildString, 32),
        locale = ns.Clip(ns.SafeCall(GetLocale), 8) or "",
        region = math.floor(region),
    }
end

local function raw()
    return {
        getUnitName = ns.Clip(ns.SafeCall(GetUnitName, "player", true), 100),
        unitName = tuple(ns.SafeCall(UnitName, "player")),
        unitFullName = tuple(ns.SafeCall(UnitFullName, "player")),
        realmName = ns.Clip(ns.SafeCall(GetRealmName), 100),
    }
end

local function fullName(r)
    if r.getUnitName and r.getUnitName ~= "" then return r.getUnitName end
    local first, second = ns.SafeCall(UnitFullName, "player")
    if first and second and second ~= "" then return first .. " " .. second end
    return first or ""
end

local function normalizeGuid(guid)
    if type(guid) ~= "string" then return nil end
    local prefix, digits, hex = string.match(guid, "^(Player%-)(%d+)%-(%x+)$")
    if not prefix or #digits > 5 or #hex ~= 8 then return nil end
    return prefix .. digits .. "-" .. string.upper(hex)
end

local function ruleset()
    local db = LedgerLinkCharDB
    local value = type(db) == "table" and db.ruleset or nil
    if RULESETS[value] then return value end
    return Json.null
end

function Identity.Who()
    local rawGuid = ns.SafeCall(UnitGUID, "player")
    local guid = normalizeGuid(rawGuid)
    if not guid then
        return nil, "Unexpected player GUID format: " .. tostring(rawGuid) .. ". Please report this."
    end
    local _, classToken = ns.SafeCall(UnitClass, "player")
    if type(classToken) ~= "string" or not string.match(classToken, "^%u%u+$") then
        return nil, "Couldn't read your class. Please report this."
    end
    local level = ns.AsId(ns.SafeCall(UnitLevel, "player"))
    if not level or level < 1 or level > 100 then
        return nil, "Couldn't read your level. Please report this."
    end
    local _, raceToken = ns.SafeCall(UnitRace, "player")
    local faction = ns.SafeCall(UnitFactionGroup, "player")
    local r = raw()
    return {
        guid = guid,
        fullName = ns.Clip(fullName(r), 100),
        raw = r,
        ruleset = ruleset(),
        class = ns.Clip(classToken, 16),
        race = ns.Clip(raceToken, 32) or "",
        level = level,
        faction = FACTIONS[faction] and faction or "Neutral",
        guildName = ns.Clip(ns.SafeCall(GetGuildInfo, "player"), 64),
    }
end
