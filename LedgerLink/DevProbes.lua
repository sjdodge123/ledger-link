-- /rl dev probes (Raid Ledger ROK-2190, dev-bridge v1): LedgerLink is the
-- developer tunnel into the game. Raid Ledger's agents queue read-only probes
-- through the Raid Ledger Companion, which writes them into DevQueue.lua as
-- `RaidLedgerProbeQueue = [==[<probe-queue JSON>]==]`. Only while dev mode is
-- on (`/rl dev on`), LedgerLink reads that JSON once per load, runs each probe
-- after its `after` event, and keeps the answer as
--
--   LedgerLinkDB.dev.probes[probeId] = "<probe-result JSON>"
--
-- which the client saves on PLAYER_LOGOUT (/reload, logout, exit), like the
-- dev snapshot. The format is Raid Ledger's (contract/dev-bridge/v1:
-- `probe-queue`, `probe-result`, allowlist.json). Every `fn` is checked
-- against the pinned allowlist (DevAllowlist.lua, generated) before EVERY
-- call; name-bearing functions are presence only; every call runs in pcall.
local _, ns = ...

local Json = ns.Json
local Probe = ns.Probe
local DevSnapshot = ns.DevSnapshot
local Allow = ns.DevAllowlist
local DevProbes = {}
ns.DevProbes = DevProbes

DevProbes.QUEUE_GLOBAL = "RaidLedgerProbeQueue"
DevProbes.QUEUE_VERSION = 1
DevProbes.QUEUE_MAX = 50
DevProbes.RESULTS_MAX = 50
DevProbes.RESULT_MAX_BYTES = 65536 -- whole probe-result
DevProbes.ITEM_MAX_BYTES = 3072    -- one call without its iterations, or one iteration
DevProbes.REQUEST_MAX_BYTES = 4096 -- a queue entry with the longest flavor
DevProbes.TTL_MAX_HOURS = 168
DevProbes.EVENTS = { "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "GUILD_ROSTER_UPDATE" }

local MAX_CALLS, MAX_ARGS, MAX_ARG_UNITS, MAX_LOOP, MAX_VALUES, MAX_ERROR_UNITS = 40, 8, 128, 200, 40, 512
local LOOP_TOKEN = "$i"
local WORST_FLAVOR = "_" .. string.rep("z", 32) .. "_" -- the longest flavor the contract allows
local CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
-- A fallback call item ({"id":<32 chars>,"status":"missing","truncated":true}) is 77 bytes; one is
-- reserved for every call still to run, so the result can always list all of them.
local HEAD_RESERVE = 96

local function set(list, lower)
    local out = {}
    for _, v in ipairs(list) do out[lower and string.lower(v) or v] = true end
    return out
end

local ALLOW_PREFIXES, ALLOW_EXACT = set(Allow.allowPrefixes), set(Allow.allowExact)
local DENY_WORDS, DENY_EXACT = set(Allow.denyWords, true), set(Allow.denyExact, true)
local DENY_PAIRS, REDACT = {}, {}
for i, pair in ipairs(Allow.denyWordPairs) do DENY_PAIRS[i] = { string.lower(pair[1]), string.lower(pair[2]) } end
for _, rule in ipairs(Allow.redact) do REDACT[rule.fn] = rule end
local AFTER = set(DevProbes.EVENTS)

local function bytes(v) return #Json.encode(v) end
local function scrub(s) return (string.gsub(s, "Player%-%d+%-%x+", "<guid>")) end
local function errorText(e) return ns.ClipUtf16(scrub(tostring(e)), MAX_ERROR_UNITS) end

-- ---------------------------------------------------------------------------
-- Allowlist (contract/dev-bridge/v1/allowlist.json, `tokenizer` rule)
-- ---------------------------------------------------------------------------

--- The words of one path segment: split at "_", then before an uppercase letter that follows a
--- lowercase letter or digit, or that starts a capitalised word after an acronym run.
function DevProbes.Words(segment)
    local words = {}
    for piece in string.gmatch(segment .. "_", "([^_]*)_") do
        local word = ""
        for i = 1, #piece do
            local c = string.sub(piece, i, i)
            if i > 1 and string.find(c, "^%u$") then
                local prev, nxt = string.sub(piece, i - 1, i - 1), string.sub(piece, i + 1, i + 1)
                if string.find(prev, "^[%l%d]$") or (string.find(prev, "^%u$") and string.find(nxt, "^%l$")) then
                    words[#words + 1], word = word, ""
                end
            end
            word = word .. c
        end
        if word ~= "" then words[#words + 1] = word end
    end
    return words
end

local function segments(path)
    local out, start = {}, 1
    while true do
        local dot = string.find(path, ".", start, true)
        if not dot then
            out[#out + 1] = string.sub(path, start)
            return out
        end
        out[#out + 1] = string.sub(path, start, dot - 1)
        start = dot + 1
    end
end

--- 1-3 dot-separated identifiers (the contract's path grammar).
local function validPath(path)
    if type(path) ~= "string" or #path < 1 or #path > 160 then return false end
    local segs = segments(path)
    if #segs > Allow.maxSegments then return false end
    for _, seg in ipairs(segs) do
        if not string.find(seg, Allow.segmentPattern) then return false end
    end
    return true
end

--- The allowlist verdict for a `fn` path: true, or false and why. Deny wins.
function DevProbes.Check(path)
    if not validPath(path) then return false, "not a function path (1-3 identifiers)" end
    local segs = segments(path)
    for _, seg in ipairs(segs) do
        if DENY_EXACT[string.lower(seg)] then return false, "deny list: " .. seg end
        local words = {}
        for _, word in ipairs(DevProbes.Words(seg)) do
            local lower = string.lower(word)
            if DENY_WORDS[lower] then return false, "deny list: " .. word end
            words[lower] = true
        end
        for _, pair in ipairs(DENY_PAIRS) do
            if words[pair[1]] and words[pair[2]] then return false, "deny list: " .. pair[1] .. " + " .. pair[2] end
        end
    end
    if ALLOW_EXACT[path] then return true end
    local last = segs[#segs]
    if ALLOW_PREFIXES[DevProbes.Words(last)[1] or ""] and not string.find(last, "_", 1, true) then return true end
    return false, "not a read: the allowlist allows Get/Is/Has/Can/Unit/Num calls"
end

--- Why LedgerLink will not call `path` (allowlist or name-bearing), or nil.
local function refusal(path)
    local ok, why = DevProbes.Check(path)
    if not ok then return why end
    if Probe.NAME_BEARING[path] or Probe.NAME_BEARING[string.match(path, "([^.]+)$")] then
        return "name-bearing: LedgerLink reports it as presence only"
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Queue (`$defs/probe-queue`)
-- ---------------------------------------------------------------------------

--- Unix seconds a probe was queued: its id is a ULID (48-bit millisecond time first).
function DevProbes.QueuedAt(probeId)
    if type(probeId) ~= "string" or #probeId ~= 26 or not string.find(probeId, "^[0-9A-HJKMNP-TV-Z]+$") then
        return nil
    end
    local ms = 0
    for i = 1, 10 do ms = ms * 32 + (string.find(CROCKFORD, string.sub(probeId, i, i), 1, true) - 1) end
    return math.floor(ms / 1000)
end

local function object(t, keys)
    if type(t) ~= "table" or Json.isArray(t) then return false end
    for k in pairs(t) do
        if not keys[k] then return false end
    end
    return true
end

local function array(t, min, max) return type(t) == "table" and Json.isArray(t) and #t >= min and #t <= max end
local function int(n, min, max) return type(n) == "number" and n == math.floor(n) and n >= min and n <= max end
local function callId(s) return type(s) == "string" and #s <= 32 and string.find(s, "^[A-Za-z][A-Za-z0-9_]*$") ~= nil end

local ENTRY_KEYS = set({ "probeId", "title", "flavor", "after", "ttlHours", "calls" })
local CALL_KEYS = set({ "id", "fn", "presence", "args", "forEach" })
local FOREACH_KEYS = set({ "countFrom", "max" })

local function validArg(a)
    local kind = type(a)
    if kind == "string" then return ns.ClipUtf16(a, MAX_ARG_UNITS) == a end
    return kind == "number" or kind == "boolean" or a == Json.null
end

local function checkCall(call, index, seen)
    local at = "calls." .. (index - 1)
    if not object(call, CALL_KEYS) then return at .. ": not a call" end
    if not callId(call.id) or seen[call.id] then return at .. ".id: missing, malformed or repeated" end
    if (call.fn == nil) == (call.presence == nil) then return at .. ": needs exactly one of fn / presence" end
    if not validPath(call.fn or call.presence) then return at .. ": not a function path" end
    if call.presence and (call.args ~= nil or call.forEach ~= nil) then return at .. ": presence takes no args" end
    if call.args ~= nil then
        if not array(call.args, 0, MAX_ARGS) then return at .. ".args: not an array of at most 8" end
        for _, a in ipairs(call.args) do
            if not validArg(a) then return at .. ".args: only short literals" end
            if a == LOOP_TOKEN and not call.forEach then return at .. ".args: $i needs forEach" end
        end
    end
    if call.forEach ~= nil then
        local loop = call.forEach
        if not object(loop, FOREACH_KEYS) or not int(loop.max, 1, MAX_LOOP) then return at .. ".forEach: malformed" end
        local from = seen[loop.countFrom]
        if not callId(loop.countFrom) or not from or from.fn == nil then
            return at .. ".forEach.countFrom: must name an earlier fn call"
        end
    end
    seen[call.id] = call
    return nil
end

--- nil when `entry` is a valid probe-queue entry, else why not.
function DevProbes.CheckEntry(entry)
    if not object(entry, ENTRY_KEYS) then return "not a probe" end
    if not DevProbes.QueuedAt(entry.probeId) then return "probeId: not a ULID" end
    local title = entry.title
    if type(title) ~= "string" or not string.find(title, "%S") or string.find(title, "%c")
        or ns.ClipUtf16(title, 120) ~= title then
        return "title: malformed"
    end
    if type(entry.flavor) ~= "string" or #entry.flavor > 34 or not string.find(entry.flavor, "^_[a-z0-9_]+_$") then
        return "flavor: not a flavor folder"
    end
    if not AFTER[entry.after] then return "after: unknown event" end
    if not int(entry.ttlHours, 1, DevProbes.TTL_MAX_HOURS) then return "ttlHours: not 1-168" end
    if not array(entry.calls, 1, MAX_CALLS) then return "calls: not 1-40 calls" end
    local seen = {}
    for index, call in ipairs(entry.calls) do
        local why = checkCall(call, index, seen)
        if why then return why end
    end
    local worst = {}
    for k, v in pairs(entry) do worst[k] = v end
    worst.flavor = WORST_FLAVOR
    if bytes(worst) > DevProbes.REQUEST_MAX_BYTES then return "over 4 KiB" end
    return nil
end

--- The valid entries of a probe-queue JSON text, and { index, reason } per refused one (index 0: the file).
function DevProbes.ParseQueue(text)
    local ok, queue = pcall(Json.decode, text)
    if not ok then return {}, { { index = 0, reason = errorText(queue) } } end
    if not object(queue, set({ "queueVersion", "probes" })) or queue.queueVersion ~= DevProbes.QUEUE_VERSION
        or not array(queue.probes, 0, DevProbes.QUEUE_MAX) then
        return {}, { { index = 0, reason = "not a queueVersion 1 probe-queue" } }
    end
    local entries, refused = {}, {}
    for index, entry in ipairs(queue.probes) do
        local why = DevProbes.CheckEntry(entry)
        if why then refused[#refused + 1] = { index = index, reason = why } else entries[#entries + 1] = entry end
    end
    return entries, refused
end

-- ---------------------------------------------------------------------------
-- Running a probe (`$defs/probe-result`)
-- ---------------------------------------------------------------------------

--- ns.VERSION as the contract's addonVersion (semver; the packager writes the tag, e.g. "v1.6.0").
function DevProbes.AddonVersion()
    local v = string.gsub(tostring(ns.VERSION or ""), "^v", "")
    local core, rest = string.match(v, "^(%d+%.%d+%.%d+)(.*)$")
    if core and #v <= 48 and not string.find(core, "%d%d%d%d%d") then
        if rest == "" or (#rest <= 33 and string.find(rest, "^%-[0-9A-Za-z.-]+$")) then return v end
    end
    return "0.0.0-dev" -- an unpackaged checkout ("@project-version@")
end

local function argList(args, i)
    local out, n = {}, 0
    if args then
        n = #args
        for k = 1, n do
            local a = args[k]
            if a == Json.null then a = nil elseif a == LOOP_TOKEN then a = i end
            out[k] = a
        end
    end
    return out, n
end

--- One call: { status, values?, error?, truncated?, first = raw first return }.
local function invoke(path, args, i)
    local why = refusal(path) -- before EVERY call, loop iterations included
    if why then return { status = "denied", error = why } end
    local found, fn = pcall(Probe.resolve, path)
    if not found or type(fn) ~= "function" then return { status = "missing" } end
    local argv, argc = argList(args, i)
    local results = { pcall(fn, unpack(argv, 1, argc)) }
    if not results[1] then return { status = "error", error = errorText(results[2]) } end
    local n = table.maxn(results) - 1
    local redact = REDACT[path]
    if redact then
        for _, slot in ipairs(redact.returns) do
            if slot <= n then results[slot + 1] = redact.replacement end
        end
    end
    local cut, values = {}, Json.array()
    for k = 1, math.min(n, MAX_VALUES) do values[k] = DevSnapshot.JsonValue(results[k + 1], 0, cut) end
    return { status = "ok", values = values, first = results[2], truncated = (n > MAX_VALUES or cut.truncated) or nil }
end

local function presence(path)
    local found, v = pcall(Probe.resolve, path)
    return { status = "ok", values = Json.array({ found and type(v) or "nil" }) }
end

-- Cut `item` to ITEM_MAX_BYTES: trailing values first (a lone value still too big goes too,
-- leaving values = []), then the error text. True when anything was cut.
local function fit(item)
    local size = bytes(item)
    if size <= DevProbes.ITEM_MAX_BYTES then return false end
    local values = item.values
    if values and #values > 0 then
        local sizes, total = {}, 0
        for k, v in ipairs(values) do sizes[k] = bytes(v) total = total + sizes[k] end
        size = size - total - (#values - 1) -- the item with values = []
        local keep, used = 0, 0
        for k = 1, #values do
            local add = sizes[k] + (k > 1 and 1 or 0)
            if size + used + add > DevProbes.ITEM_MAX_BYTES then break end
            keep, used = k, used + add
        end
        for k = #values, keep + 1, -1 do values[k] = nil end
        size = bytes(item)
    end
    while item.error and size > DevProbes.ITEM_MAX_BYTES do
        item.error = ns.Clip(item.error, math.max(#item.error - (size - DevProbes.ITEM_MAX_BYTES), 0))
        size = bytes(item)
    end
    return true
end

--- The call item without iterations, fitted. `truncated` is measured as set, then dropped if unused.
local function head(call, r)
    local item = { id = call.id, status = r.status, values = r.values, error = r.error, truncated = true }
    local cut = fit(item)
    if not (cut or r.truncated) then item.truncated = nil end
    return item
end

--- Run one probe-queue entry; the probe-result table (Json.encode gives the stored string).
function DevProbes.Run(entry)
    local result = {
        probeId = entry.probeId,
        capturedAt = date("!%Y-%m-%dT%H:%M:%SZ"),
        addonVersion = DevProbes.AddonVersion(),
        calls = Json.array(),
        truncated = false,
    }
    local budget, firsts, count = DevProbes.RESULT_MAX_BYTES - bytes(result), {}, #entry.calls
    for index, call in ipairs(entry.calls) do
        local avail = budget - HEAD_RESERVE * (count - index) - (index > 1 and 1 or 0)
        local r, loops
        if call.presence then
            r = presence(call.presence)
        elseif call.forEach then
            local why, n = refusal(call.fn), firsts[call.forEach.countFrom]
            if why then
                r = { status = "denied", error = why }
            elseif type(n) ~= "number" or n ~= n then
                r = { status = "error", error = "countFrom " .. call.forEach.countFrom .. " did not return a number" }
            else
                r, loops = { status = "ok" }, math.min(math.floor(n), call.forEach.max)
            end
        else
            r = invoke(call.fn, call.args)
            if r.status == "ok" then firsts[call.id] = r.first end
        end
        local item = head(call, r)
        local wasTruncated = item.truncated
        item.truncated = true -- measure every head as if cut: it may be, by the budget below
        if loops then item.iterations = Json.array() end
        local cost = bytes(item)
        if cost > avail then
            item, loops = { id = call.id, status = r.status, truncated = true }, nil
            cost, wasTruncated = bytes(item), true
        end
        for i = 1, loops or 0 do
            local step = invoke(call.fn, call.args, i)
            local iteration = { i = i, status = step.status, values = step.values, error = step.error }
            if fit(iteration) or step.truncated then wasTruncated = true end
            local add = bytes(iteration) + (i > 1 and 1 or 0)
            if cost + add > avail then
                wasTruncated = true
                break
            end
            item.iterations[i], cost = iteration, cost + add
        end
        item.truncated = wasTruncated or nil
        if wasTruncated then result.truncated = true end
        result.calls[index] = item
        budget = budget - cost - (index > 1 and 1 or 0)
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Storage (LedgerLinkDB.dev.probes) and the load / event flow
-- ---------------------------------------------------------------------------

local function stored()
    if not DevSnapshot.Enabled() then return nil end
    local dev = LedgerLinkDB.dev
    if type(dev.probes) ~= "table" then dev.probes = {} end
    if type(dev.probeExpiresAt) ~= "table" then dev.probeExpiresAt = {} end
    return dev.probes, dev.probeExpiresAt
end

function DevProbes.Count()
    local n = 0
    for _ in pairs(stored() or {}) do n = n + 1 end
    return n
end

local function expiresAt(entry) return DevProbes.QueuedAt(entry.probeId) + entry.ttlHours * 3600 end
local function expired(entry, now) return now > expiresAt(entry) end

--- Drop expired results (past their probe's ttlHours, kept in dev.probeExpiresAt when the result is
--- stored; 168 h, the longest TTL, when that is unknown) and anything malformed, then keep the newest
--- RESULTS_MAX (ULIDs sort by time).
function DevProbes.Prune(now)
    local probes, expires = stored()
    if not probes then return end
    now = now or time()
    local ids = {}
    for id, json in pairs(probes) do
        local at = DevProbes.QueuedAt(id)
        local deadline = at and (tonumber(expires[id]) or at + DevProbes.TTL_MAX_HOURS * 3600)
        if not at or type(json) ~= "string" or now > deadline then
            probes[id] = nil
        else
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    for i = 1, #ids - DevProbes.RESULTS_MAX do probes[ids[i]] = nil end
    for id in pairs(expires) do
        if probes[id] == nil then expires[id] = nil end
    end
end

DevProbes.pending = {}

--- ADDON_LOADED (ns.Init): read the queue once, only in dev mode. Returns how many probes wait to run.
function DevProbes.Load()
    DevProbes.pending, DevProbes.refused = {}, {}
    if not DevSnapshot.Enabled() then return 0 end -- dev mode off: the queue is never read
    DevProbes.Prune()
    local text = _G[DevProbes.QUEUE_GLOBAL]
    if type(text) ~= "string" then return 0 end
    local entries, refused = DevProbes.ParseQueue(text)
    DevProbes.refused = refused
    if #refused > 0 then
        local first = refused[1]
        ns.Print(string.format("Dev probe queue: %d entr%s refused (%s: %s).", #refused, #refused == 1 and "y" or "ies",
            first.index == 0 and "the file" or ("probe " .. first.index), first.reason))
    end
    local probes, now = stored(), time()
    for _, entry in ipairs(entries) do
        if probes[entry.probeId] == nil and not expired(entry, now) then
            DevProbes.pending[#DevProbes.pending + 1] = entry
        end
    end
    return #DevProbes.pending
end

--- Run and store one entry; true when a result was stored.
function DevProbes.Answer(entry)
    local probes = stored()
    if not probes or probes[entry.probeId] ~= nil or expired(entry, time()) then return false end
    local ok, json = pcall(function() return Json.encode(DevProbes.Run(entry)) end)
    if not ok or #json > DevProbes.RESULT_MAX_BYTES then
        ns.Print("Dev probe " .. entry.probeId .. " failed: " .. (ok and "result over 64 KiB" or errorText(json)))
        return false
    end
    local _, expires = stored()
    probes[entry.probeId], expires[entry.probeId] = json, expiresAt(entry)
    DevProbes.Prune()
    return true
end

--- Run every pending probe waiting for `event`.
function DevProbes.OnEvent(event)
    if #DevProbes.pending == 0 or not DevSnapshot.Enabled() then return 0 end
    local waiting, answered = {}, 0
    for _, entry in ipairs(DevProbes.pending) do
        if entry.after ~= event then
            waiting[#waiting + 1] = entry
        elseif DevProbes.Answer(entry) then
            answered = answered + 1
        end
    end
    DevProbes.pending = waiting
    if answered > 0 then
        ns.Print(string.format("Answered %d dev probe(s) for the Raid Ledger Companion. They are saved at your next"
            .. " /reload or logout.", answered))
    end
    return answered
end

DevProbes.frame = CreateFrame("Frame")
for _, event in ipairs(DevProbes.EVENTS) do DevProbes.frame:RegisterEvent(event) end
DevProbes.frame:SetScript("OnEvent", function(_, event) DevProbes.OnEvent(event) end)
