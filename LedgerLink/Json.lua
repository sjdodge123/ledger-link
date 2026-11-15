-- Minimal, deterministic JSON encoder.
--
-- Why not C_EncodingUtil.SerializeJSON: a Lua table cannot say "this empty
-- table is an array" or "this key is null", and the Raid Ledger server is
-- strict (`gear: []`, `ruleset: null` and `unitName: [name, null]` must be
-- exact). How SerializeJSON renders those is UNVERIFIED on Forever (spike E8),
-- so the addon owns its JSON and only uses C_EncodingUtil to compress and
-- base64-encode.
local _, ns = ...

local Json = {}
ns.Json = Json

--- Sentinel encoded as JSON `null`.
Json.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY_MT = { __ledgerLinkArray = true }

--- Mark a table as a JSON array (encoded `[]` even when empty).
function Json.array(t)
    return setmetatable(t or {}, ARRAY_MT)
end

function Json.isArray(t)
    return getmetatable(t) == ARRAY_MT
end

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escapeChar(c)
    return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
end

local function encodeString(s)
    return '"' .. string.gsub(s, '[%c"\\]', escapeChar) .. '"'
end

local function encodeNumber(n)
    if n ~= n or n == math.huge or n == -math.huge then
        error("LedgerLink JSON: cannot encode a non-finite number", 0)
    end
    if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
        return string.format("%d", n)
    end
    return string.format("%.14g", n)
end

local encodeValue

local function encodeArray(t, out)
    out[#out + 1] = "["
    for i = 1, #t do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(t[i], out)
    end
    out[#out + 1] = "]"
end

local function encodeObject(t, out)
    local keys = {}
    for k in pairs(t) do
        if type(k) ~= "string" then
            error("LedgerLink JSON: object keys must be strings", 0)
        end
        keys[#keys + 1] = k
    end
    table.sort(keys)
    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(k)
        out[#out + 1] = ":"
        encodeValue(t[k], out)
    end
    out[#out + 1] = "}"
end

encodeValue = function(v, out)
    local kind = type(v)
    if v == Json.null then
        out[#out + 1] = "null"
    elseif kind == "string" then
        out[#out + 1] = encodeString(v)
    elseif kind == "number" then
        out[#out + 1] = encodeNumber(v)
    elseif kind == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif kind == "table" then
        if Json.isArray(v) then encodeArray(v, out) else encodeObject(v, out) end
    else
        error("LedgerLink JSON: cannot encode a " .. kind, 0)
    end
end

--- Encode a value. Plain tables are objects; use Json.array for arrays.
function Json.encode(value)
    local out = {}
    encodeValue(value, out)
    return table.concat(out)
end

-- Decoder: only /rl dev reads JSON (the Raid Ledger Companion's probe queue,
-- DevProbes.lua). Arrays come back marked with Json.array and `null` as
-- Json.null, so Json.encode gives the same JSON (and byte count) back.
local UNESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
local MAX_DEPTH = 32

local function utf8Char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

--- Decode a JSON text. Throws "LedgerLink JSON: ..." on anything malformed.
function Json.decode(text)
    if type(text) ~= "string" then error("LedgerLink JSON: not a string", 0) end
    local pos = 1
    local function fail(what) error(string.format("LedgerLink JSON: %s at byte %d", what, pos), 0) end
    local function skip() pos = string.find(text, "[^ \t\r\n]", pos) or #text + 1 end
    local function hex4(at)
        local digits = string.sub(text, at, at + 3)
        if not string.find(digits, "^%x%x%x%x$") then return nil end
        return tonumber(digits, 16)
    end

    local function decodeString()
        pos = pos + 1
        local out = {}
        while true do
            local at = string.find(text, '[%z\1-\31"\\]', pos)
            if not at then fail("unterminated string") end
            out[#out + 1] = string.sub(text, pos, at - 1)
            local c = string.sub(text, at, at)
            if c == '"' then pos = at + 1 return table.concat(out) end
            if c ~= "\\" then pos = at fail("raw control character in a string") end
            local e = string.sub(text, at + 1, at + 1)
            if UNESCAPES[e] then
                out[#out + 1], pos = UNESCAPES[e], at + 2
            elseif e == "u" then
                local cp = hex4(at + 2)
                if not cp then pos = at fail("bad \\u escape") end
                pos = at + 6
                local low = string.sub(text, pos, pos + 1) == "\\u" and hex4(pos + 2)
                if cp >= 0xD800 and cp <= 0xDBFF and low and low >= 0xDC00 and low <= 0xDFFF then
                    cp, pos = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00), pos + 6
                end
                out[#out + 1] = utf8Char(cp)
            else
                pos = at fail("bad escape")
            end
        end
    end

    local decodeValue
    local function decodeArray(depth)
        local out = Json.array()
        pos = pos + 1
        skip()
        if string.sub(text, pos, pos) == "]" then pos = pos + 1 return out end
        while true do
            out[#out + 1] = decodeValue(depth + 1)
            skip()
            local c = string.sub(text, pos, pos)
            pos = pos + 1
            if c == "]" then return out end
            if c ~= "," then pos = pos - 1 fail("expected , or ]") end
        end
    end

    local function decodeObject(depth)
        local out = {}
        pos = pos + 1
        skip()
        if string.sub(text, pos, pos) == "}" then pos = pos + 1 return out end
        while true do
            skip()
            if string.sub(text, pos, pos) ~= '"' then fail("expected a string key") end
            local key = decodeString()
            skip()
            if string.sub(text, pos, pos) ~= ":" then fail("expected :") end
            pos = pos + 1
            out[key] = decodeValue(depth + 1)
            skip()
            local c = string.sub(text, pos, pos)
            pos = pos + 1
            if c == "}" then return out end
            if c ~= "," then pos = pos - 1 fail("expected , or }") end
        end
    end

    decodeValue = function(depth)
        if depth > MAX_DEPTH then fail("nested too deep") end
        skip()
        local c = string.sub(text, pos, pos)
        if c == "{" then return decodeObject(depth) end
        if c == "[" then return decodeArray(depth) end
        if c == '"' then return decodeString() end
        for literal, value in pairs({ ["true"] = true, ["false"] = false, null = Json.null }) do
            if string.sub(text, pos, pos + #literal - 1) == literal then
                pos = pos + #literal
                return value
            end
        end
        local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        local n = number and tonumber(number)
        if not n or n ~= n or n == math.huge or n == -math.huge then fail("unexpected character") end
        pos = pos + #number
        return n
    end

    local value = decodeValue(0)
    skip()
    if pos <= #text then fail("trailing characters") end
    return value
end
