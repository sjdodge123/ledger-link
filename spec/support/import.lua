-- Test-side mirror of Raid Ledger's decodeImportString guard order, raising
-- {code = ...} with the server's error codes so contract/v1/fixtures/invalid/
-- can be checked. Limits are Raid Ledger's (packages/contract/src/
-- wow-addon-import.schema.ts). Schema validation (INVALID_PAYLOAD) is not done
-- here: callers run the returned page JSON through tools/validate-contract.mjs.
local LibDeflate = require("LibDeflate")
local base64 = require("spec.support.base64")
local dkjson = require("dkjson")

local MAX_BYTES = 262144 -- ADDON_IMPORT_MAX_BYTES
local MAX_DECODED_BYTES = 1048576 -- ADDON_IMPORT_MAX_DECODED_BYTES
local MAX_PAGES = 8 -- ADDON_IMPORT_MAX_PAGES
local ENVELOPE_VERSION = 1 -- ADDON_EXPORT_ENVELOPE_VERSION
local SECTIONS = { char = true, guild = true, raid = true }

local function fail(code) error({ code = code }, 0) end

-- ADDON_IMPORT_PAGE_RE: ^!RL(\d+)!(char|guild|raid)(?:-(\d+)of(\d+))?!([A-Za-z0-9+/]+={0,2})$
local function parseHeader(token)
    local version, section, paging, body = token:match("^!RL(%d+)!(%l+)(%-?[%dof]*)!([A-Za-z0-9+/=]+)$")
    local page, of = (paging or ""):match("^%-(%d+)of(%d+)$")
    if not version or not SECTIONS[section] or (paging ~= "" and not page)
        or not body:match("^[A-Za-z0-9+/]+=?=?$") then
        fail("BAD_HEADER")
    end
    if tonumber(version) ~= ENVELOPE_VERSION then fail("UNSUPPORTED_VERSION") end
    if not page then return { section = section, body = body } end
    page, of = tonumber(page), tonumber(of)
    if section ~= "guild" or of < 1 or of > MAX_PAGES or page < 1 or page > of then fail("BAD_HEADER") end
    return { section = section, page = page, of = of, body = body }
end

-- A single unpaged string, or every page 1..M of one guild export exactly once.
local function assertPageSet(headers)
    if #headers == 1 and not headers[1].page then return headers end
    local seen = {}
    for _, h in ipairs(headers) do
        if not h.page or h.of ~= headers[1].of or seen[h.page] then fail("PAGES_INCOMPLETE") end
        seen[h.page] = true
    end
    if #headers ~= headers[1].of then fail("PAGES_INCOMPLETE") end
    table.sort(headers, function(a, b) return a.page < b.page end)
    return headers
end

local function decodePage(header)
    if #header.body % 4 ~= 0 then fail("CUT_OFF") end
    local json = LibDeflate:DecompressZlib(base64.decode(header.body))
    if not json then fail("CUT_OFF") end
    if #json > MAX_DECODED_BYTES then fail("DECODED_TOO_LARGE") end
    local payload = dkjson.decode(json, 1, dkjson.null)
    if type(payload) ~= "table" then fail("CUT_OFF") end
    return { json = json, payload = payload }
end

-- Returns { pages = n, sections = {...}, jsons = {page JSON, sorted}, payloads = {...} }.
return function(raw)
    local input = raw:match("^%s*(.-)%s*$")
    if #input > MAX_BYTES then fail("TOO_LARGE") end
    if input == "" then fail("BAD_HEADER") end
    local tokens = {}
    for token in input:gmatch("%S+") do tokens[#tokens + 1] = token end
    if #tokens > MAX_PAGES then fail("PAGES_INCOMPLETE") end
    local headers = {}
    for i, token in ipairs(tokens) do headers[i] = parseHeader(token) end
    headers = assertPageSet(headers)
    local result = { pages = #headers, sections = {}, jsons = {}, payloads = {} }
    for i, h in ipairs(headers) do
        local page = decodePage(h)
        result.sections[i], result.jsons[i], result.payloads[i] = h.section, page.json, page.payload
    end
    return result
end
