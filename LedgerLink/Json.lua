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
