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

--- Region ids the contract accepts (client.region), by the name players type.
Identity.REGIONS = { us = 1, kr = 2, eu = 3, tw = 4, cn = 5 }

--- GetCurrentRegion() when it is a real region (1-5). The WoW: Forever beta
--- returns 90 (portal "test"), so there the player's choice (/rl region) is used.
function Identity.Region()
    local region = ns.SafeCall(GetCurrentRegion)
    if type(region) == "number" and region >= 1 and region <= 5 then
        return math.floor(region)
    end
    local chosen = Identity.REGIONS[LedgerLinkDB and LedgerLinkDB.region or ""]
    if chosen then return chosen end
    return nil, "This client doesn't report a real region (GetCurrentRegion returned "
        .. tostring(region) .. "). Set yours once with /rl region us|eu|kr|tw|cn."
end

function Identity.Client()
    local version, build, _, interface = ns.SafeCall(GetBuildInfo)
    local region, regionErr = Identity.Region()
    if not region then return nil, regionErr end
    local buildString = tostring(version or "?")
    if build then buildString = buildString .. "." .. tostring(build) end
    return {
        interface = ns.AsId(interface) or 0,
        build = ns.Clip(buildString, 32),
        locale = ns.Clip(ns.SafeCall(GetLocale), 8) or "",
        region = region,
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

--- `Player-<1-5 digits>-<8 hex>` with upper-case hex, or nil (contract AddonGuidSchema).
function ns.NormalizeGuid(guid)
    if type(guid) ~= "string" then return nil end
    local prefix, digits, hex = string.match(guid, "^(Player%-)(%d+)%-(%x+)$")
    if not prefix or #digits > 5 or #hex ~= 8 then return nil end
    return prefix .. digits .. "-" .. string.upper(hex)
end

--- The client has no realm-type API. C_GameRules.IsHardcoreActive() exists
--- on the WoW: Forever beta (false on PvP and PvE realms; true on Hardcore is
--- UNVERIFIED, see README "Beta unknowns"). Only a real `true` counts.
local function detectRuleset()
    local rules = C_GameRules
    if type(rules) == "table" and ns.SafeCall(rules.IsHardcoreActive) == true then return "hardcore" end
    return nil
end

--- This character's ruleset and where it came from: the player's own pick
--- ("set") always wins, else what the game reports ("detected"), else nil.
function Identity.Ruleset()
    local db = LedgerLinkCharDB
    local value = type(db) == "table" and db.ruleset or nil
    if RULESETS[value] then return value, "set" end
    local detected = detectRuleset()
    if detected then return detected, "detected" end
    return nil
end

--- "pvp", "hardcore (detected)" or "not set", for the panel, tooltip and status.
function Identity.RulesetText()
    local value, source = Identity.Ruleset()
    if not value then return "not set" end
    return source == "detected" and (value .. " (detected)") or value
end

local function ruleset()
    return Identity.Ruleset() or Json.null
end

function Identity.Who()
    local rawGuid = ns.SafeCall(UnitGUID, "player")
    local guid = ns.NormalizeGuid(rawGuid)
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
