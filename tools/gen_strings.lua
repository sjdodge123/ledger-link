-- Generate addon export strings (char, guild incl. multi-page, raid) with the
-- WoW stub, one file per case, for tools/verify-with-raid-ledger.sh. A paged
-- guild case is written as ONE paste (pages joined by newlines), plus a
-- `-reversed` copy with the pages in reverse order.
-- Usage: luajit tools/gen_strings.lua <outdir>
package.path = "./?.lua;" .. package.path
local loadAddon = require("spec.support.load_addon")
local outDir = assert(arg[1], "usage: gen_strings.lua <outdir>")

local function raidPulls(ns, count, raidSize)
    WowStub.raid(raidSize)
    for i = 1, count do
        ns.Raid.OnEvent("ENCOUNTER_START", 660 + i, "Boss " .. i, 9, 40)
        WowStub.state.serverTime = WowStub.state.serverTime + 300
        ns.Raid.OnEvent("ENCOUNTER_END", 660 + i, "Boss " .. i, 9, 40, i % 3 == 0 and 0 or 1)
    end
end

local cases = {
    { name = "char-full-normal", section = "char", setup = function(ns) ns.HandleSlash("ruleset normal") end },
    { name = "char-roleplaying", section = "char", setup = function(ns) ns.HandleSlash("ruleset rp") end },
    { name = "char-ruleset-null-no-guild-empty", section = "char", setup = function()
        local s = WowStub.state
        s.guild, s.gear, s.lockouts, s.talentConfigId = nil, {}, {}, nil
    end },
    { name = "char-urlsafe-base64-client", section = "char",
        setup = function() WowStub.state.base64Variant = "urlsafe-unpadded" end },
    { name = "guild-small-single-page", section = "guild", setup = function() end },
    { name = "guild-notes-on", section = "guild", setup = function(ns) ns.HandleSlash("guildnotes on") end },
    { name = "guild-600-3pages", section = "guild", reversed = true,
        setup = function() WowStub.state.guildRoster = WowStub.roster(600) end },
    { name = "guild-2000-8pages", section = "guild", reversed = true,
        setup = function() WowStub.state.guildRoster = WowStub.roster(2000) end },
    { name = "guild-2100-capped", section = "guild",
        setup = function() WowStub.state.guildRoster = WowStub.roster(2100) end },
    { name = "raid-1-pull", section = "raid", setup = function(ns) raidPulls(ns, 1, 40) end },
    { name = "raid-50-pulls-ring-full", section = "raid", setup = function(ns) raidPulls(ns, 60, 40) end },
}

local function write(name, text)
    local f = assert(io.open(outDir .. "/" .. name .. ".txt", "w"))
    f:write(text)
    f:close()
end

for _, case in ipairs(cases) do
    local ns = loadAddon()
    case.setup(ns)
    local pages = assert(ns.Export.RunPages(case.section))
    write(case.name, table.concat(pages, "\n"))
    if case.reversed then
        local rev = {}
        for i = #pages, 1, -1 do rev[#rev + 1] = pages[i] end
        write(case.name .. "-reversed", table.concat(rev, "\n"))
    end
    local bytes = 0
    for _, p in ipairs(pages) do bytes = bytes + #p end
    print(string.format("%s %d page(s) %d bytes", case.name, #pages, bytes))
end
