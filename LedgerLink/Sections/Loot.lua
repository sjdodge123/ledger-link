-- Loot history recorder (Raid Ledger ROK-2184, contract v2 DRAFT §3 `loot`).
--
-- NOT EXPORTED. The `loot` section only exists in the v2 wire format, which is
-- still a Raid Ledger draft (planning-artifacts/specs/ROK-2184-...-DRAFT.md):
-- nothing here registers with Export, so no `!RL1!loot` / `!RL2!` string can be
-- built. Once Raid Ledger lands `ledgerlink/v2/` and deploys a server that
-- accepts it, the switch is: re-sync contract/v2, check Loot.Build against
-- contract/v2/schema.json, register the section and move every section to
-- `!RL2!` + `schema: 2` at once (draft §7).
--
-- Until then it records, so the first v2 export has history: every loot line
-- (CHAT_MSG_LOOT) that names an item of quality >= MIN_QUALITY, received by
-- anyone in the group, while the player is in a party or raid inside a party
-- or raid instance. Drops live in LedgerLinkDB.loot.drops (oldest first), for
-- WINDOW_SECONDS, at most MAX_DROPS. No roll numbers, no chat text is kept.
--
-- The lines are matched with the client's own GlobalStrings (LOOT_ITEM, ...),
-- so any game language works. Chat arguments may be secret values on a
-- 12.0-era client: a secret line is counted and skipped, never read.
local _, ns = ...

local Json = ns.Json
local Loot = {}
ns.Loot = Loot

--- Draft §3: keep a rolling 30-day window and send all of it.
Loot.WINDOW_SECONDS = 30 * 24 * 3600
--- Draft ADDON_LOOT_DROPS_MAX.
Loot.MAX_DROPS = 500
--- Draft §3: lowest item quality recorded (2 = uncommon).
Loot.MIN_QUALITY = 2
--- Draft attribution rule: a kill in the same instance at most this long before the drop.
Loot.ATTRIBUTION_SECONDS = 300
--- A "won" line pairs with the same looter's receive line of the same item this soon after.
Loot.ROLL_MATCH_SECONDS = 60
--- Contract caps (draft §3).
local MAX_LINK, MAX_NAME, MAX_ENCOUNTER_NAME, MAX_QUANTITY = 512, 100, 128, 1000
--- Contract unixSeconds ceiling (2100-01-01).
local UNIX_SECONDS_MAX = 4102444800

local function secret(v)
    return type(issecretvalue) == "function" and issecretvalue(v) == true
end

--- What happened to loot lines this session (/rl probe S10). Not saved.
Loot.stats = { seen = 0, recorded = 0, outside = 0, lowQuality = 0, secret = 0, unparsed = 0, notItem = 0 }

local function store()
    if type(LedgerLinkDB) ~= "table" then LedgerLinkDB = {} end
    local l = LedgerLinkDB.loot
    if type(l) ~= "table" then
        -- Recording starts now: the window never claims time before it.
        l = { since = ns.Raid.Now() }
        LedgerLinkDB.loot = l
    end
    if type(l.drops) ~= "table" then l.drops = {} end
    if type(l.since) ~= "number" or l.since ~= l.since then l.since = ns.Raid.Now() end
    return l
end

function Loot.Drops() return store().drops end

--- Start of the window the stored drops cover.
function Loot.Since() return store().since end

-- Forget drops older than the window and beyond the cap. The window start
-- moves with them: it is the oldest moment the addon still holds records for.
local function prune(l, now)
    local oldest = now - Loot.WINDOW_SECONDS
    local start = 1
    while l.drops[start] and not (type(l.drops[start].at) == "number" and l.drops[start].at >= oldest) do
        start = start + 1
    end
    local capStart = #l.drops - Loot.MAX_DROPS + 1
    local overCap = capStart > start
    start = math.max(start, capStart)
    if start > 1 then
        local kept = {}
        for i = start, #l.drops do kept[#kept + 1] = l.drops[i] end
        l.drops = kept
        -- A recent drop left out for the cap: the window starts at the oldest one kept.
        if overCap and kept[1] then l.since = math.max(l.since, kept[1].at) end
    end
    l.since = math.min(math.max(l.since, oldest), now)
end

-- GlobalStrings format -> anchored Lua pattern + which capture holds which
-- argument ("%s", "%d" and the positional "%2$s" some languages use).
local function compile(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local parts, order, pos, n = { "^" }, {}, 1, 0
    while true do
        local s, e, index, kind = string.find(fmt, "%%(%d*)%$?([sd])", pos)
        local literal = string.sub(fmt, pos, (s or 0) - 1)
        if not s then literal = string.sub(fmt, pos) end
        parts[#parts + 1] = (string.gsub(literal, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
        if not s then break end
        n = n + 1
        order[n] = tonumber(index) or n
        parts[#parts + 1] = kind == "d" and "(%d+)" or "(.+)"
        pos = e + 1
    end
    parts[#parts + 1] = "$"
    return { pattern = table.concat(parts), order = order }
end

-- Which loot lines are read, most specific first: "x%d" lines before the
-- single ones (whose "%s" would swallow the multiplier), and "You ..." lines
-- before the "%s ..." ones (whose "%s" would read "You" as a name). `self`
-- lines have no name; `won` lines mark a won roll (the receive line follows).
local LINES = {
    { name = "LOOT_ITEM_SELF_MULTIPLE", args = { "link", "quantity" }, self = true },
    { name = "LOOT_ITEM_MULTIPLE", args = { "name", "link", "quantity" } },
    { name = "LOOT_ITEM_SELF", args = { "link" }, self = true },
    { name = "LOOT_ITEM", args = { "name", "link" } },
    { name = "LOOT_ROLL_YOU_WON", args = { "link" }, self = true, won = true },
    { name = "LOOT_ROLL_WON", args = { "name", "link" }, won = true },
}
Loot.LINE_STRINGS = {}
for i, line in ipairs(LINES) do Loot.LINE_STRINGS[i] = line.name end

local compiled
local function matchers()
    if compiled then return compiled end
    compiled = {}
    for _, line in ipairs(LINES) do
        local c = compile(rawget(_G, line.name))
        if c then
            c.line = line
            compiled[#compiled + 1] = c
        end
    end
    return compiled
end

--- Forget the compiled GlobalStrings (tests change them).
function Loot.ResetMatchers() compiled = nil end

--- Parse one loot line: { name?, link, quantity, self, won } or nil.
function Loot.Parse(text)
    if type(text) ~= "string" then return nil end
    for _, c in ipairs(matchers()) do
        local caps = { string.match(text, c.pattern) }
        if caps[1] ~= nil then
            local out = { self = c.line.self == true, won = c.line.won == true }
            for i, arg in ipairs(c.line.args) do out[arg] = caps[c.order[i]] end
            out.quantity = tonumber(out.quantity) or 1
            return out
        end
    end
    return nil
end

-- Link colours: Blizzard's quality colours, and the "|cnIQ<n>:" form.
local QUALITY_BY_COLOUR = {
    ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5, e6cc80 = 6, ["00ccff"] = 7,
}

local function qualityOf(link)
    local iq = string.match(link, "|cnIQ(%d):")
    if iq then return tonumber(iq) end
    local colour = string.match(link, "|c%x%x(%x%x%x%x%x%x)")
    local q = colour and QUALITY_BY_COLOUR[string.lower(colour)]
    if q then return q end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local _, _, info = ns.SafeCall(getInfo, link)
    q = ns.AsId(info)
    if q and q <= 7 then return q end
    return nil
end

-- A name as the loot line prints it: player link and colour codes removed.
local function plainName(name)
    if type(name) ~= "string" or secret(name) then return nil end
    name = string.match(name, "|Hplayer:[^|]*|h%[?(.-)%]?|h") or name
    name = string.gsub(string.gsub(name, "|c%x%x%x%x%x%x%x%x", ""), "|r", "")
    name = string.match(name, "^%s*(.-)%s*$")
    if name == "" then return nil end
    return ns.ClipUtf16(name, MAX_NAME)
end

local function selfName()
    local name = ns.SafeCall(GetUnitName, "player", true)
    if type(name) ~= "string" or secret(name) then return nil end
    return plainName(name)
end

local function baseName(name) return (string.match(name, "^(.-)%-[^%-]*$")) or name end

--- The group member called `name`: their GUID, or nil when not in the group.
function Loot.GuidFor(name)
    local guids, names = ns.Raid.Roster()
    for i, n in ipairs(names) do
        if n == name then return guids[i] end
    end
    local base = baseName(name)
    for i, n in ipairs(names) do
        if baseName(n) == base then return guids[i] end
    end
    return nil
end

--- In a party or raid, inside a dungeon or raid instance (draft §3).
function Loot.Recording()
    local grouped = ns.SafeCall(IsInGroup)
    if grouped == nil then grouped = (ns.AsId(ns.SafeCall(GetNumGroupMembers)) or 0) > 0 end
    if not grouped then return false end
    local inside, kind = ns.SafeCall(IsInInstance)
    return inside == true and (kind == "party" or kind == "raid")
end

-- The group's loot method: "master", "freeforall", "roundrobin", "group",
-- "needbeforegreed", "personal" or nil (C_PartyInfo first, then the legacy global).
local METHOD_NAMES = { "freeforall", "roundrobin", "master", "group", "needbeforegreed", "personal" }
local LEGACY_METHODS = { personalloot = "personal" }

function Loot.Method()
    local value = C_PartyInfo and ns.SafeCall(C_PartyInfo.GetLootMethod)
    if type(value) == "number" then
        local enum = Enum and Enum.LootMethod
        if type(enum) == "table" then
            local byValue = {
                [enum.Freeforall or 0] = "freeforall", [enum.Roundrobin or 1] = "roundrobin",
                [enum.Masterlooter or 2] = "master", [enum.Group or 3] = "group",
                [enum.Needbeforegreed or 4] = "needbeforegreed", [enum.Personal or 5] = "personal",
            }
            return byValue[value]
        end
        return METHOD_NAMES[value + 1]
    end
    value = ns.SafeCall(GetLootMethod)
    if type(value) == "string" then return LEGACY_METHODS[value] or value end
    return nil
end

-- How the looter got the item: draft `method`.
local function methodFor(wonRoll, quality)
    if wonRoll then return "roll" end
    local method = Loot.Method()
    local threshold = ns.AsId(ns.SafeCall(GetLootThreshold))
    local belowThreshold = quality and threshold and quality < threshold
    if method == "master" then return belowThreshold and "direct" or "master" end
    if method == "freeforall" or method == "roundrobin" or method == "personal" then return "direct" end
    if (method == "group" or method == "needbeforegreed") and belowThreshold then return "direct" end
    return "unknown"
end

-- Draft attribution rule: the most recent successful kill in the same
-- instance, ended at most ATTRIBUTION_SECONDS before the drop.
local function attribute(at, instanceId)
    if not instanceId then return nil end
    local pulls = ns.Raid.Pulls()
    for i = #pulls, 1, -1 do
        local p = pulls[i]
        if type(p) == "table" and p.success == true and p.instanceId == instanceId
            and type(p.endAt) == "number" and p.endAt <= at then
            if at - p.endAt <= Loot.ATTRIBUTION_SECONDS then return p end
            return nil
        end
    end
    return nil
end

-- Roll wins waiting for their receive line: { key, itemId, at }. Not saved.
local wins = {}

local function takeWin(key, itemId, now)
    for i = #wins, 1, -1 do
        local w = wins[i]
        if now - w.at > Loot.ROLL_MATCH_SECONDS then
            table.remove(wins, i)
        elseif w.key == key and w.itemId == itemId then
            table.remove(wins, i)
            return true
        end
    end
    return false
end

--- What the last loot line's event arguments looked like, for /rl probe S10
--- (never saved; no secret value is kept). guidArg: "secret", "empty",
--- "not a player GUID" or the GUID; looterGuid: what the roster gave.
Loot.last = nil

local function describeArgs(playerName, eventGuid)
    local nameArg = "empty"
    if secret(playerName) then
        nameArg = "secret"
    elseif type(playerName) == "string" and playerName ~= "" then
        nameArg = "readable"
    end
    local guidArg = "empty"
    if secret(eventGuid) then
        guidArg = "secret"
    elseif type(eventGuid) == "string" and eventGuid ~= "" then
        guidArg = ns.NormalizeGuid(eventGuid) or "not a player GUID"
    end
    return { nameArg = nameArg, guidArg = guidArg }
end

--- CHAT_MSG_LOOT(text, playerName, ..., guid [12th]).
function Loot.OnLoot(text, playerName, ...)
    local stats = Loot.stats
    stats.seen = stats.seen + 1
    local last = describeArgs(playerName, (select(10, ...)))
    Loot.last = last
    if secret(text) or secret(playerName) then
        stats.secret = stats.secret + 1
        return
    end
    if not Loot.Recording() then
        stats.outside = stats.outside + 1
        return
    end
    local parsed = Loot.Parse(text)
    if not parsed then
        stats.unparsed = stats.unparsed + 1
        Loot.lastUnparsed = ns.Clip(text, 160)
        return
    end
    local itemId = ns.AsId(tonumber(string.match(parsed.link, "|Hitem:(%d+)")))
    if not itemId or itemId < 1 then
        stats.notItem = stats.notItem + 1
        return
    end
    local quality = qualityOf(parsed.link)
    if quality and quality < Loot.MIN_QUALITY then
        stats.lowQuality = stats.lowQuality + 1
        return
    end
    local name = parsed.self and selfName() or plainName(parsed.name) or plainName(playerName)
    if not name then
        stats.unparsed = stats.unparsed + 1
        return
    end
    local now = ns.Raid.Now()
    if parsed.won then
        wins[#wins + 1] = { key = baseName(name), itemId = itemId, at = now }
        return
    end
    local looterGuid = Loot.GuidFor(name)
    last.looterGuid = looterGuid or "not in the group"
    Loot.Record({
        at = now,
        itemId = itemId,
        link = #parsed.link <= MAX_LINK and parsed.link or nil,
        quantity = math.max(1, math.min(parsed.quantity, MAX_QUANTITY)),
        quality = quality,
        looterName = name,
        looterGuid = looterGuid,
        method = methodFor(takeWin(baseName(name), itemId, now), quality),
    })
end

--- Store one drop (instance, difficulty and boss are filled in here).
function Loot.Record(drop)
    local _, _, difficultyId, _, _, _, _, instanceId = ns.SafeCall(GetInstanceInfo)
    drop.instanceId = ns.AsId(instanceId)
    drop.difficultyId = ns.AsId(difficultyId)
    local kill = attribute(drop.at, drop.instanceId)
    if kill then
        drop.encounterId = ns.AsId(kill.encounterId)
        drop.encounterName = ns.ClipUtf16(kill.name, MAX_ENCOUNTER_NAME)
    end
    local l = store()
    l.drops[#l.drops + 1] = drop
    prune(l, drop.at)
    Loot.stats.recorded = Loot.stats.recorded + 1
end

local METHODS = { master = true, roll = true, direct = true, unknown = true }

-- SavedVariables may be stale or hand-edited: each stored drop is
-- re-validated into exactly the draft keys, or left out.
local function exportRow(d, windowStart, windowEnd)
    if type(d) ~= "table" then return nil end
    local at, itemId = ns.AsId(d.at), ns.AsId(d.itemId)
    if not at or at < windowStart or at > windowEnd or not itemId or itemId < 1 then return nil end
    local name = plainName(d.looterName)
    if not name then return nil end
    local quantity = ns.AsId(d.quantity) or 1
    local quality = ns.AsId(d.quality)
    local encounterId = ns.AsId(d.encounterId)
    return {
        at = at,
        itemId = itemId,
        link = type(d.link) == "string" and #d.link <= MAX_LINK and d.link or nil,
        quantity = math.max(1, math.min(quantity, MAX_QUANTITY)),
        quality = quality and quality <= 7 and quality or nil,
        looterName = name,
        looterGuid = ns.NormalizeGuid(d.looterGuid),
        method = METHODS[d.method] and d.method or "unknown",
        instanceId = ns.AsId(d.instanceId),
        difficultyId = ns.AsId(d.difficultyId),
        encounterId = encounterId,
        encounterName = encounterId and ns.ClipUtf16(d.encounterName, MAX_ENCOUNTER_NAME) or nil,
    }
end

--- The newest `keep` drops of built loot `data`; the window starts at the
--- oldest drop kept when older ones are left out (draft §5).
function Loot.Newest(data, keep)
    local drops = Json.array()
    local first = math.max(#data.drops - keep + 1, 1)
    for i = first, #data.drops do drops[#drops + 1] = data.drops[i] end
    local windowStart = data.windowStart
    if first > 1 and drops[1] then windowStart = math.max(windowStart, drops[1].at) end
    return { windowStart = windowStart, windowEnd = data.windowEnd, minQuality = data.minQuality, drops = drops }
end

--- The draft v2 `loot` section `data` (§3). Never fails: `drops` may be empty.
function Loot.Build()
    local now = ns.Raid.Now()
    local l = store()
    prune(l, now)
    local windowStart = math.min(math.max(ns.AsId(l.since) or now, 0), now)
    local rows = {}
    for _, d in ipairs(l.drops) do
        local row = exportRow(d, windowStart, now)
        if row then rows[#rows + 1] = row end
    end
    table.sort(rows, function(a, b) return a.at < b.at end)
    return Loot.Newest({ windowStart = windowStart, windowEnd = math.min(now, UNIX_SECONDS_MAX),
        minQuality = Loot.MIN_QUALITY, drops = rows }, Loot.MAX_DROPS)
end

local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_LOOT")
events:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_LOOT" then Loot.OnLoot(...) end
end)
