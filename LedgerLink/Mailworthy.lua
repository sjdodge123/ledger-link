-- Mailworthy guild contributions (Raid Ledger ROK-2148): the `char` section's
-- optional `data.mailworthy` block (contract v1 CONTRACT.md §3.1).
--
-- The data comes from the Mailworthy addon's read-only API,
-- MailworthyAPI.v1.GetGuildExport(guildName). Mailworthy already builds Raid
-- Ledger's shape, but a newer Mailworthy could add keys or raise caps, and
-- Raid Ledger rejects the whole string on any unknown key. So the result is
-- rebuilt here from the keys the schema knows, with the contract's caps:
-- an entry that doesn't fit is dropped (a name is never shortened), an empty
-- list is left out (except `template.rules`, sent as []), and a block with
-- nothing left is not sent. No Mailworthy, no guild, a nil result or an error
-- means no `mailworthy` key: this must never break the char export.
local _, ns = ...

local Json = ns.Json
local Mailworthy = {}
ns.Mailworthy = Mailworthy

-- Contract limits (Raid Ledger wow-addon-mailworthy.schema.ts).
Mailworthy.NAME_MAX = 48
Mailworthy.RULES_MAX = 8
Mailworthy.PEERS_MAX = 1000
Mailworthy.GIVERS_MAX = 200
Mailworthy.DAYS_MAX = 35
local UNIX_MAX = 4102444800 -- 2100-01-01: a millisecond value is out of range
local COUNT_MAX = 2147483647 -- Postgres int4
local DAY_MAX = 47482 -- floor(UNIX_MAX / 86400)

-- Raid Ledger measures names as JavaScript strings (UTF-16 code units): one
-- per UTF-8 character, two for a 4-byte one.
local function utf16Length(s)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then n = n + 1 end
        if b >= 0xF0 then n = n + 1 end
    end
    return n
end

--- A name of 1 to NAME_MAX characters, else nil (never shortened).
function Mailworthy.Name(s)
    if type(s) ~= "string" or s == "" or utf16Length(s) > Mailworthy.NAME_MAX then return nil end
    return s
end

-- A whole number in [min, max], else nil.
local function int(x, min, max)
    if type(x) ~= "number" or x ~= x or x < min or x > max then return nil end
    return math.floor(x)
end

local function unixTime(x) return int(x, 1, UNIX_MAX) end
local function count(x) return int(x, 0, COUNT_MAX) end

local function list(t) return type(t) == "table" and t or {} end

local function template(t)
    if type(t) ~= "table" or type(t.rules) ~= "table" then return nil end
    local rev, author = unixTime(t.rev), Mailworthy.Name(t.author)
    if not rev or not author then return nil end
    local rules = Json.array()
    for _, r in ipairs(t.rules) do
        if #rules >= Mailworthy.RULES_MAX then break end
        local skillLine = type(r) == "table" and int(r.professionSkillLineId, 1, COUNT_MAX)
        local recipient = type(r) == "table" and Mailworthy.Name(r.recipientName)
        if skillLine and recipient then
            rules[#rules + 1] = { professionSkillLineId = skillLine, recipientName = recipient }
        end
    end
    return { rev = rev, author = author, rules = rules }
end

-- Newest first (ties by name, so the order is stable), one per name.
local function peers(t)
    local all = {}
    for _, p in ipairs(list(t)) do
        local name = type(p) == "table" and Mailworthy.Name(p.name)
        local seen = type(p) == "table" and unixTime(p.lastSeenAt)
        if name and seen then all[#all + 1] = { name = name, lastSeenAt = seen } end
    end
    table.sort(all, function(a, b)
        if a.lastSeenAt ~= b.lastSeenAt then return a.lastSeenAt > b.lastSeenAt end
        return a.name < b.name
    end)
    local out, named = Json.array(), {}
    for _, p in ipairs(all) do
        if #out >= Mailworthy.PEERS_MAX then break end
        if not named[p.name] then
            named[p.name] = true
            out[#out + 1] = p
        end
    end
    return #out > 0 and out or nil
end

-- Non-zero UTC days, ascending, one per day, the newest DAYS_MAX.
local function days(t)
    local all = {}
    for _, d in ipairs(list(t)) do
        local day = type(d) == "table" and int(d.day, 0, DAY_MAX)
        local items = type(d) == "table" and count(d.items)
        if day and items and items > 0 then all[#all + 1] = { day = day, items = items } end
    end
    table.sort(all, function(a, b) return a.day < b.day end)
    local unique = {}
    for _, d in ipairs(all) do
        if not unique[1] or unique[#unique].day ~= d.day then unique[#unique + 1] = d end
    end
    local out = Json.array()
    for i = math.max(1, #unique - Mailworthy.DAYS_MAX + 1), #unique do out[#out + 1] = unique[i] end
    return out
end

-- Mailworthy's order (its own characters first, then the most items), the
-- first GIVERS_MAX. A giver whose `asOf` is after `generatedAt` would reject
-- the whole string, so it is dropped.
local function givers(t, generatedAt)
    local out = Json.array()
    for _, g in ipairs(list(t)) do
        if #out >= Mailworthy.GIVERS_MAX then break end
        if type(g) == "table" then
            local name, total = Mailworthy.Name(g.characterName), count(g.itemsAllTime)
            local since, asOf = unixTime(g.countingSince), unixTime(g.asOf)
            if name and total and since and asOf and asOf <= generatedAt then
                out[#out + 1] = { characterName = name, itemsAllTime = total, countingSince = since,
                    asOf = asOf, days = days(g.days) }
            end
        end
    end
    return #out > 0 and out or nil
end

--- The contract block rebuilt from a GetGuildExport() result; nil when
--- nothing valid is left.
function Mailworthy.Clean(raw)
    if type(raw) ~= "table" then return nil end
    local generatedAt = unixTime(raw.generatedAt)
    if not generatedAt then return nil end
    local block = {
        generatedAt = generatedAt,
        template = template(raw.template),
        peers = peers(raw.peers),
        givers = givers(raw.givers, generatedAt),
    }
    if not block.template and not block.peers and not block.givers then return nil end
    return block
end

local function build()
    -- Guild.Name() falls back to the roster cached while playing: at
    -- PLAYER_LOGOUT GetGuildInfo("player") already returns nil.
    local guild = ns.Guild and ns.Guild.Name()
    if type(guild) ~= "string" or guild == "" then return nil end
    local api = type(MailworthyAPI) == "table" and type(MailworthyAPI.v1) == "table"
        and MailworthyAPI.v1.GetGuildExport or nil
    if type(api) ~= "function" then return nil end
    return Mailworthy.Clean(api(guild))
end

--- The `data.mailworthy` block for this character's guild, or nil (no key).
function Mailworthy.Block()
    local ok, block = pcall(build)
    return ok and block or nil
end
