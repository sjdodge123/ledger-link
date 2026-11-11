-- Who is exporting: the `client` and `who` envelope blocks.
-- Raw identity calls are stored as returned; Raid Ledger decides the name.
local _, ns = ...

local Json = ns.Json
local Identity = {}
ns.Identity = Identity

local RULESETS = { normal = true, pvp = true, roleplaying = true, rppvp = true, hardcore = true }
--- How a ruleset reads in the panel, tooltip and /rl status (the wire value otherwise).
local RULESET_LABELS = { rppvp = "RP-PvP" }
local FACTIONS = { Alliance = true, Horde = true, Neutral = true }

--- Call a WoW API that may be missing or throw on a beta build.
function ns.SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local results = { pcall(fn, ...) }
    if not results[1] then return nil end
    return unpack(results, 2, table.maxn(results))
end

--- Truncate a string to at most `max` bytes without splitting a UTF-8 character;
--- nil for anything that isn't a string.
function ns.Clip(s, max)
    if type(s) ~= "string" then return nil end
    if #s <= max then return s end
    -- Never split a UTF-8 character: if the cut lands inside one, drop it whole.
    local cut = max
    local nextByte = s:byte(cut + 1)
    if nextByte and nextByte >= 0x80 and nextByte < 0xC0 then
        while cut > 0 and s:byte(cut) >= 0x80 and s:byte(cut) < 0xC0 do cut = cut - 1 end
        cut = cut - 1
    end
    return string.sub(s, 1, math.max(cut, 0))
end

--- Truncate a string to at most `max` UTF-16 code units (how the contract
--- counts a string's length) without splitting a UTF-8 character; nil for
--- anything that isn't a string. A 4-byte character is 2 units, any other 1.
function ns.ClipUtf16(s, max)
    if type(s) ~= "string" then return nil end
    if #s <= max then return s end -- a unit is never less than a byte
    local units, i, len = 0, 1, #s
    while i <= len do
        local lead = s:byte(i)
        local size = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
        -- A malformed or cut-off character: count its bytes one by one.
        for j = i + 1, i + size - 1 do
            local b = s:byte(j)
            if not b or b < 0x80 or b > 0xBF then size = 1 break end
        end
        local cost = size == 4 and 2 or 1
        if units + cost > max then break end
        units, i = units + cost, i + size
    end
    return string.sub(s, 1, i - 1)
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

--- Game language -> region, used only when the client doesn't report a region
--- (the WoW: Forever beta returns 90) and the player hasn't picked one, so
--- players never have to type /rl region. A guess, shown as one; never saved.
Identity.LOCALE_REGION = {
    enUS = "us", esMX = "us", ptBR = "us",
    enGB = "eu", deDE = "eu", frFR = "eu", esES = "eu", itIT = "eu", ruRU = "eu", ptPT = "eu",
    koKR = "kr", zhTW = "tw", zhCN = "cn",
}

--- The region id (1-5) and where it came from: "client" (GetCurrentRegion,
--- expected on live), "set" (/rl region or the panel) or "guessed" (game
--- language; unknown languages guess us). Never nil.
function Identity.Region()
    local region = ns.SafeCall(GetCurrentRegion)
    if type(region) == "number" and region >= 1 and region <= 5 then
        return math.floor(region), "client"
    end
    local chosen = Identity.REGIONS[LedgerLinkDB and LedgerLinkDB.region or ""]
    if chosen then return chosen, "set" end
    local guess = Identity.LOCALE_REGION[ns.SafeCall(GetLocale) or ""] or "us"
    return Identity.REGIONS[guess], "guessed"
end

--- The region's short name ("us", "eu", ...).
function Identity.RegionName()
    local id = Identity.Region()
    for name, value in pairs(Identity.REGIONS) do
        if value == id then return name end
    end
end

--- For the panel and /rl status; nil when the game reports the region itself.
function Identity.RegionText()
    local _, source = Identity.Region()
    if source == "client" then return nil end
    local name = Identity.RegionName()
    if source == "set" then return name end
    return name .. " (guessed from your game language; /rl region to change)"
end

function Identity.Client()
    local version, build, _, interface = ns.SafeCall(GetBuildInfo)
    local region = Identity.Region()
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

--- "RP PvP", "RP-PvP" or "RPPvP" as a whole word somewhere in the realm name
--- (live realms are named like "CAMWOW US2 Realm 9 RP PvP", Raid Ledger
--- ROK-2101). Case-insensitive; "Sharpvp" does not match.
local RPPVP_IN_REALM_NAME = "%f[%w]rp[%s%-]*pvp%f[%W]"

function Identity.IsRpPvpRealmName(name)
    return type(name) == "string" and string.find(string.lower(name), RPPVP_IN_REALM_NAME) ~= nil
end

--- The client has no realm-type API in game (the realm list's isRP/isPvP are
--- glue-screen only). C_GameRules.IsHardcoreActive() exists on the WoW:
--- Forever beta (false on PvP and PvE realms; true on Hardcore is UNVERIFIED,
--- see README "Beta unknowns"); only a real `true` counts. RP-PvP is read off
--- GetRealmName(), the one place the client spells the realm type out.
local function detectRuleset()
    local rules = C_GameRules
    if type(rules) == "table" and ns.SafeCall(rules.IsHardcoreActive) == true then return "hardcore" end
    if Identity.IsRpPvpRealmName(ns.SafeCall(GetRealmName)) then return "rppvp" end
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

--- "pvp", "RP-PvP", "hardcore (detected)" or "not set", for the panel, tooltip and status.
function Identity.RulesetText()
    local value, source = Identity.Ruleset()
    if not value then return "not set" end
    local text = RULESET_LABELS[value] or value
    return source == "detected" and (text .. " (detected)") or text
end

local function ruleset()
    return Identity.Ruleset() or Json.null
end

--- UnitSex: 2 male, 3 female; anything else (1 = unknown) is left out.
local GENDERS = { [2] = "male", [3] = "female" }

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
        -- Live, else the cached roster's name (at logout GetGuildInfo is nil).
        guildName = ns.Guild and ns.Guild.Name() or ns.Clip(ns.SafeCall(GetGuildInfo, "player"), 64),
        gender = GENDERS[ns.SafeCall(UnitSex, "player") or 0],
    }
end
