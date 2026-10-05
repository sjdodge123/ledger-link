-- Envelope builder + encode pipeline:
--   !RL1!<section>!<base64( zlib( json(payload) ) )>
-- json is ours (Json.lua); zlib + base64 are C_EncodingUtil.
local _, ns = ...

local Export = {}
ns.Export = Export

Export.ENVELOPE_VERSION = 1
Export.PAYLOAD_SCHEMA = 1
--- Refuse to show a string bigger than this (spike §4a: suggest paging).
Export.MAX_STRING_BYTES = 200 * 1024
--- The whole paste (every page + separators) must fit the server's
--- ADDON_IMPORT_MAX_BYTES (wow-addon-import.schema.ts).
Export.MAX_PASTE_BYTES = 262144
--- Server ADDON_IMPORT_MAX_PAGES: pages accepted in one paste.
Export.MAX_PAGES = 8

local builders = {}

--- builder() returns the section's `data` table, or nil + an error message.
--- opts.paginate(data) -> list of per-page `data` tables (all sharing the
--- envelope); opts.prepare(done) runs before the builder (async allowed).
function Export.RegisterSection(name, builder, opts)
    opts = opts or {}
    builders[name] = { build = builder, paginate = opts.paginate, prepare = opts.prepare }
end

--- Run the section's prepare step (e.g. a guild roster refresh), then done().
function Export.Prepare(section, done)
    local entry = builders[section]
    if entry and entry.prepare then
        entry.prepare(done)
    else
        done()
    end
end

function Export.BuildPayload(section, data)
    local client, clientErr = ns.Identity.Client()
    if not client then return nil, clientErr end
    local who, whoErr = ns.Identity.Who()
    if not who then return nil, whoErr end
    return {
        schema = Export.PAYLOAD_SCHEMA,
        section = section,
        addonVersion = ns.VERSION,
        client = client,
        exportedAt = math.floor(ns.SafeCall(GetServerTime) or time()),
        who = who,
        data = data,
    }
end

local function compressionArgs()
    local methods = Enum and Enum.CompressionMethod
    local levels = Enum and Enum.CompressionLevel
    local zlib = methods and methods.Zlib or 1
    return zlib, levels and levels.OptimizeForSize or nil
end

--- Normalise to STANDARD base64 with padding (the server requires it);
--- tolerates a URL-safe or unpadded EncodeBase64 (spike E8 is unverified).
function Export.NormalizeBase64(b64)
    b64 = string.gsub(b64, "%s", "")
    b64 = string.gsub(b64, "%-", "+")
    b64 = string.gsub(b64, "_", "/")
    local pad = (4 - #b64 % 4) % 4
    if pad == 3 then return nil end
    return b64 .. string.rep("=", pad)
end

--- Encode a payload table into the paste string.
function Export.Encode(section, payload, pageSuffix)
    local codec = C_EncodingUtil
    if type(codec) ~= "table" or not codec.CompressString or not codec.EncodeBase64 then
        return nil, "C_EncodingUtil is missing on this client - export is unavailable. Please report this."
    end
    local okJson, json = pcall(ns.Json.encode, payload)
    if not okJson then return nil, "Couldn't serialise the export: " .. tostring(json) end
    local method, level = compressionArgs()
    local compressed = ns.SafeCall(codec.CompressString, json, method, level)
    if type(compressed) ~= "string" then return nil, "Compression failed. Please report this." end
    local b64 = Export.NormalizeBase64(ns.SafeCall(codec.EncodeBase64, compressed) or "")
    if not b64 or b64 == "" then return nil, "Base64 encoding failed. Please report this." end
    local header = "!RL" .. Export.ENVELOPE_VERSION .. "!" .. section .. (pageSuffix or "") .. "!"
    return header .. b64
end

local function encodePages(section, payload, chunks)
    local pages, total = {}, 0
    for i, chunk in ipairs(chunks) do
        -- One envelope for every page: same exportedAt + who (the server
        -- refuses to merge pages from different exports).
        payload.data = chunk
        local suffix = #chunks > 1 and string.format("-%dof%d", i, #chunks) or nil
        local str, err = Export.Encode(section, payload, suffix)
        if not str then return nil, err end
        if #str > Export.MAX_STRING_BYTES then
            return nil, string.format("The %s export is too large (%d KB).", section, math.floor(#str / 1024))
        end
        total = total + #str + (i > 1 and 1 or 0)
        pages[i] = str
    end
    if total > Export.MAX_PASTE_BYTES then
        return nil, string.format("The %s export is too large to import (%d KB over %d pages; Raid Ledger takes %d KB).",
            section, math.floor(total / 1024), #pages, Export.MAX_PASTE_BYTES / 1024)
    end
    return pages
end

--- Build + encode one section. Returns a list of page strings (one for an
--- unpaged section), or nil + a message.
function Export.RunPages(section)
    local entry = builders[section]
    if not entry then
        return nil, "Unknown section '" .. tostring(section) .. "'. Use char, guild or raid."
    end
    local data, dataErr = entry.build()
    if not data then return nil, dataErr end
    local payload, payloadErr = Export.BuildPayload(section, data)
    if not payload then return nil, payloadErr end
    local chunks = entry.paginate and entry.paginate(data) or { data }
    if #chunks < 1 or #chunks > Export.MAX_PAGES then
        return nil, string.format("The %s export needs %d pages; Raid Ledger takes at most %d.",
            section, #chunks, Export.MAX_PAGES)
    end
    return encodePages(section, payload, chunks)
end

--- Build + encode one section as ONE paste: pages joined by newlines (the
--- server accepts whitespace-separated pages in one box). nil + a message on error.
function Export.Run(section)
    local pages, err = Export.RunPages(section)
    if not pages then return nil, err end
    return table.concat(pages, "\n")
end
