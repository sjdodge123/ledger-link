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
--- Server ADDON_IMPORT_MAX_PAGES: pages of one guild export.
Export.MAX_PAGES = 8

local builders = {}

--- builder() returns the section's `data` table, or nil + an error message.
--- opts.paginate(data) -> list of per-page `data` tables (all sharing the
--- envelope); opts.prepare(done) runs before the builder (async allowed).
--- opts.fit = { count(data), keep(data, n), noun }: an unpaged section whose
--- string is too large is cut to the largest n items (keep) that still fit.
function Export.RegisterSection(name, builder, opts)
    opts = opts or {}
    builders[name] = { build = builder, paginate = opts.paginate, prepare = opts.prepare, fit = opts.fit }
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
    local exportedAt = math.floor(ns.SafeCall(GetServerTime) or time())
    -- Local note for the Companion outbox (Outbox.lua); not part of the payload.
    Export.lastBuilt = { guid = who.guid, exportedAt = exportedAt }
    return {
        schema = Export.PAYLOAD_SCHEMA,
        section = section,
        addonVersion = ns.VERSION,
        client = client,
        exportedAt = exportedAt,
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

--- Bytes `text` would take once compressed + base64'd exactly like an export
--- body (for /rl probe size estimates). nil when the codec is unavailable.
function Export.EncodedSize(text)
    local codec = C_EncodingUtil
    if type(codec) ~= "table" or not codec.CompressString or not codec.EncodeBase64 then return nil end
    local method, level = compressionArgs()
    local compressed = ns.SafeCall(codec.CompressString, text, method, level)
    if type(compressed) ~= "string" then return nil end
    local b64 = ns.SafeCall(codec.EncodeBase64, compressed)
    return type(b64) == "string" and #b64 or nil
end

-- Returns the pages, or nil + a message (+ true when only the size was wrong).
-- `budget` caps the whole paste (default MAX_PASTE_BYTES).
local function encodePages(section, payload, chunks, budget)
    budget = budget or Export.MAX_PASTE_BYTES
    local pages, total = {}, 0
    for i, chunk in ipairs(chunks) do
        -- One envelope for every page: same exportedAt + who (the server
        -- refuses to merge pages from different exports).
        payload.data = chunk
        local suffix = #chunks > 1 and string.format("-%dof%d", i, #chunks) or nil
        local str, err = Export.Encode(section, payload, suffix)
        if not str then return nil, err end
        if #str > Export.MAX_STRING_BYTES then
            return nil, string.format("The %s export is too large (%d KB).", section, math.floor(#str / 1024)), true
        end
        total = total + #str + (i > 1 and 1 or 0)
        pages[i] = str
    end
    if total > budget then
        return nil, string.format("The %s export is too large to import (%d KB over %d pages; Raid Ledger takes %d KB).",
            section, math.floor(total / 1024), #pages, Export.MAX_PASTE_BYTES / 1024), true
    end
    return pages
end

-- A too-large unpaged `fit` section: binary-search the largest item count
-- whose string fits (a few compressions, not one per item), keeping the
-- builder's choice of items (raid: the newest pulls). Returns pages + a note,
-- or nil when not even one item fits.
local function fitPages(section, entry, payload, data, budget)
    local fit = entry.fit
    local total = fit.count(data)
    local lo, hi, best, kept = 1, total - 1, nil, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local pages, err, tooLarge = encodePages(section, payload, { fit.keep(data, mid) }, budget)
        if pages then
            best, kept, lo = pages, mid, mid + 1
        elseif tooLarge then
            hi = mid - 1
        else
            return nil, err
        end
    end
    if not best then return nil end
    return best, string.format("The %s export holds the newest %d of %d %s, to fit Raid Ledger's size limit.",
        section, kept, total, fit.noun or "items")
end

--- Build + encode one section. Returns a list of page strings (one for an
--- unpaged section) and, if items were left out to fit, a note; or nil, a
--- message and true when the only problem is size. `budget` caps the whole
--- paste in bytes (default MAX_PASTE_BYTES; Export all passes what is left).
function Export.RunPages(section, budget)
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
    local pages, err, tooLarge = encodePages(section, payload, chunks, budget)
    if pages or not tooLarge or not entry.fit or entry.paginate then return pages, err, tooLarge end
    local fitted, noteOrErr = fitPages(section, entry, payload, data, budget)
    if fitted then return fitted, noteOrErr end
    if noteOrErr then return nil, noteOrErr end -- encode failure while fitting
    return nil, err, true -- not even one item fits
end

--- Build + encode one section as ONE paste: pages joined by newlines (the
--- server accepts whitespace-separated pages in one box). nil + a message on error.
function Export.Run(section)
    local pages, err = Export.RunPages(section)
    if not pages then return nil, err end
    return table.concat(pages, "\n")
end

local TOO_BIG_FOR_ONE_PASTE = "That's too big for one paste. Export the guild on its own (/rl export guild),"
    .. " then the rest (/rl export char, /rl export raid)."

--- "Export all" (Raid Ledger ROK-1737, CONTRACT.md §5.1): the char string,
--- every guild page and the raid string, each in its own single-section
--- format, for one paste. Sections that don't apply are left out with a note:
--- no guild, or no recorded pulls. Returns tokens, notes or nil, error.
function Export.RunAll()
    local tokens, notes = {}, {}
    local char, charErr = Export.RunPages("char")
    if not char then return nil, charErr end
    tokens[1] = char[1]
    if ns.SafeCall(GetGuildInfo, "player") then
        local guild, guildErr = Export.RunPages("guild")
        if not guild then return nil, "Guild export: " .. tostring(guildErr) end
        for _, page in ipairs(guild) do tokens[#tokens + 1] = page end
    else
        notes[#notes + 1] = "You're not in a guild, so there's no guild section."
    end
    if #ns.Raid.Pulls() > 0 then
        -- The raid gets what is left of the one paste (plus its newline), so
        -- a full pull history is cut to its newest pulls instead of failing
        -- the whole run (ROK-2123).
        local left = Export.MAX_PASTE_BYTES - #table.concat(tokens, "\n") - 1
        local raid, raidNote, tooLarge = Export.RunPages("raid", left)
        if not raid then
            if tooLarge then return nil, TOO_BIG_FOR_ONE_PASTE end
            return nil, "Raid export: " .. tostring(raidNote)
        end
        tokens[#tokens + 1] = raid[1]
        if raidNote then notes[#notes + 1] = raidNote end
    else
        notes[#notes + 1] = "There are no boss pulls recorded, so there's no raid section."
    end
    if #table.concat(tokens, "\n") > Export.MAX_PASTE_BYTES then return nil, TOO_BIG_FOR_ONE_PASTE end
    return tokens, notes
end

