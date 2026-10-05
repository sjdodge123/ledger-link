-- Test-side decoder mirroring the Raid Ledger server: header regex,
-- base64 length % 4, zlib inflate (adler32-checked), JSON.parse.
local LibDeflate = require("LibDeflate")
local base64 = require("spec.support.base64")
local dkjson = require("dkjson")

return function(str)
    local version, section, body = str:match("^!RL(%d+)!(%a+)!([A-Za-z0-9+/]+=?=?)$")
    assert(version, "bad header: " .. str:sub(1, 20))
    assert(#body % 4 == 0, "base64 body is not padded")
    local json = assert(LibDeflate:DecompressZlib(base64.decode(body)), "zlib inflate failed")
    local payload = assert(dkjson.decode(json, 1, dkjson.null))
    return { version = tonumber(version), section = section, body = body, json = json, payload = payload }
end
