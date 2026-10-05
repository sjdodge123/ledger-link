-- Generate addon `char` export strings with the WoW stub, one file per case,
-- for tools/verify-with-raid-ledger.sh. Usage: luajit tools/gen_char_strings.lua <outdir>
package.path = "./?.lua;" .. package.path
local loadAddon = require("spec.support.load_addon")
local outDir = assert(arg[1], "usage: gen_char_strings.lua <outdir>")

local cases = {
    { name = "full-normal", setup = function(ns) ns.HandleSlash("ruleset normal") end },
    { name = "roleplaying", setup = function(ns) ns.HandleSlash("ruleset rp") end },
    { name = "ruleset-null-no-guild-empty", setup = function()
        local s = WowStub.state
        s.guild, s.gear, s.lockouts, s.talentConfigId = nil, {}, {}, nil
    end },
    { name = "urlsafe-base64-client", setup = function() WowStub.state.base64Variant = "urlsafe-unpadded" end },
}

for _, case in ipairs(cases) do
    local ns = loadAddon()
    case.setup(ns)
    local str = assert(ns.Export.Run("char"))
    local f = assert(io.open(outDir .. "/" .. case.name .. ".txt", "w"))
    f:write(str)
    f:close()
    print(case.name .. " " .. #str .. " bytes")
end
