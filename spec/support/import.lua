-- Test-side mirror of Raid Ledger's decodeImportPaste guard order (incl. the
-- ROK-1737 mixed paste, CONTRACT.md §5.1), raising
-- {code = ...} with the server's error codes so contract/v1/fixtures/invalid/
-- can be checked. Limits are Raid Ledger's (packages/contract/src/
-- wow-addon-import.schema.ts). Schema validation (INVALID_PAYLOAD) is not done
-- here: callers run the returned page JSON through tools/validate-contract.mjs.
local LibDeflate = require("LibDeflate")
local base64 = require("spec.support.base64")
local dkjson = require("dkjson")

local MAX_BYTES = 262144 -- ADDON_IMPORT_MAX_BYTES
local MAX_DECODED_BYTES = 1048576 -- ADDON_IMPORT_MAX_DECODED_BYTES
local MAX_PAGES = 8 -- ADDON_IMPORT_MAX_PAGES (one guild export's pages)
local MAX_TOKENS = 10 -- ADDON_IMPORT_MAX_TOKENS (whole paste: 8 guild pages + char + raid)
local SAME_EXPORT_WINDOW = 600 -- ADDON_IMPORT_SAME_EXPORT_WINDOW_SECONDS
local ORDER = { "char", "guild", "raid" } -- canonical section order (CONTRACT.md §5.1)
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

-- One section's tokens: a single string, or (guild only) one complete page set.
local function groupHeaders(section, headers)
    if #headers == 1 then return assertPageSet(headers) end
    if section ~= "guild" then fail("PAGES_INCOMPLETE") end -- a second char/raid string
    for _, h in ipairs(headers) do
        if not h.page then fail("PAGES_INCOMPLETE") end -- a second guild export
    end
    return assertPageSet(headers)
end

-- resolveExportName: first non-empty of fullName, raw.getUnitName,
-- raw.unitFullName joined; realm suffix dropped; whitespace collapsed;
-- compared case-insensitively (NFC is a no-op for the ASCII test data).
local function exportName(who)
    local tuple = {}
    for _, part in ipairs(type(who.raw.unitFullName) == "table" and who.raw.unitFullName or {}) do
        if type(part) == "string" and part ~= "" then tuple[#tuple + 1] = part end
    end
    for _, candidate in ipairs({ who.fullName, who.raw.getUnitName, table.concat(tuple, " ") }) do
        local name = (type(candidate) == "string" and candidate or ""):gsub("%-.*$", "")
        name = name:gsub("%s+", " "):match("^%s*(.-)%s*$")
        if name ~= "" then return name:lower() end
    end
    return ""
end

local function assertSameExporter(groups)
    if #groups < 2 then return end
    local first = groups[1].payloads[1]
    local low, high = first.exportedAt, first.exportedAt
    for _, g in ipairs(groups) do
        local p = g.payloads[1]
        if p.who.guid ~= first.who.guid or p.client.region ~= first.client.region
            or exportName(p.who) ~= exportName(first.who) then
            fail("INVALID_PAYLOAD")
        end
        low, high = math.min(low, p.exportedAt), math.max(high, p.exportedAt)
    end
    if high - low > SAME_EXPORT_WINDOW then fail("INVALID_PAYLOAD") end
end

-- Returns { groups = { { section, pages, sections = {per page}, jsons = {page JSON},
-- payloads = {...} }, ... } } in canonical order (char, guild, raid). For a
-- single-section paste the first group's fields are also copied to the top
-- level. Schema checks are the caller's (tools/validate-contract.mjs); the
-- same-exporter check needs decoded payloads and so runs only when every page
-- parsed as JSON.
-- Returns { pages = n, sections = {...}, jsons = {page JSON, sorted}, payloads = {...} }.
return function(raw)
    local input = raw:match("^%s*(.-)%s*$")
    if #input > MAX_BYTES then fail("TOO_LARGE") end
    if input == "" then fail("BAD_HEADER") end
    local tokens = {}
    for token in input:gmatch("%S+") do tokens[#tokens + 1] = token end
    if #tokens > MAX_TOKENS then fail("PAGES_INCOMPLETE") end
    local headers = {}
    for i, token in ipairs(tokens) do headers[i] = parseHeader(token) end
    local groups = {}
    for _, section in ipairs(ORDER) do
        local mine = {}
        for _, h in ipairs(headers) do
            if h.section == section then mine[#mine + 1] = h end
        end
        if #mine > 0 then groups[#groups + 1] = { section = section, headers = groupHeaders(section, mine) } end
    end
    for _, g in ipairs(groups) do
        g.pages, g.sections, g.jsons, g.payloads = #g.headers, {}, {}, {}
        for i, h in ipairs(g.headers) do
            local page = decodePage(h)
            g.sections[i], g.jsons[i], g.payloads[i] = h.section, page.json, page.payload
        end
    end
    local ok, err = pcall(assertSameExporter, groups)
    if not ok and type(err) == "table" then error(err, 0) end
    local result = { groups = groups }
    if #groups == 1 then
        for k, v in pairs(groups[1]) do result[k] = v end
    end
    return result
end
