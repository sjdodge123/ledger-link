-- Export scenarios shared by spec/contract_spec.lua and tools/gen_strings.lua:
-- char (rulesets, empty/nil data, urlsafe client base64), guild (single, notes,
-- 3 and 8 pages, capped), raid (1 pull, ring buffer full). `reversed` marks
-- paged cases that are also checked with the pages pasted in reverse order.
local loadAddon = require("spec.support.load_addon")

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

-- Returns the export pages (strings) for one case, from a freshly loaded addon.
local function run(case)
    local ns = loadAddon()
    case.setup(ns)
    return assert(ns.Export.RunPages(case.section))
end

return { cases = cases, run = run }
