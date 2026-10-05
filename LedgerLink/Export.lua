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

local builders = {}

--- builder() returns the section's `data` table, or nil + an error message.
function Export.RegisterSection(name, builder)
    builders[name] = builder
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

--- Build + encode one section. Returns the string, or nil + a message.
function Export.Run(section)
    local builder = builders[section]
    if not builder then
        return nil, "Unknown section '" .. tostring(section) .. "'. Use char, guild or raid."
    end
    local data, dataErr = builder()
    if not data then return nil, dataErr end
    local payload, payloadErr = Export.BuildPayload(section, data)
    if not payload then return nil, payloadErr end
    local str, encodeErr = Export.Encode(section, payload)
    if not str then return nil, encodeErr end
    if #str > Export.MAX_STRING_BYTES then
        return nil, string.format("The %s export is too large (%d KB).", section, math.floor(#str / 1024))
    end
    return str
end
