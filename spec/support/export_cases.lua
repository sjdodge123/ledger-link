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
    { name = "char-hardcore-detected", section = "char",
        setup = function() _G.C_GameRules = { IsHardcoreActive = function() return true end } end },
    { name = "char-ruleset-null-no-guild-empty", section = "char", setup = function()
        local s = WowStub.state
        s.guild, s.gear, s.lockouts, s.talentConfigId = nil, {}, {}, nil
    end },
    { name = "char-urlsafe-base64-client", section = "char",
        setup = function() WowStub.state.base64Variant = "urlsafe-unpadded" end },
    { name = "char-beta-region-90-player-picked-eu", section = "char", setup = function(ns)
        WowStub.state.region = 90 -- what the WoW: Forever beta reports
        ns.HandleSlash("region eu")
    end },
    { name = "char-beta-region-90-guessed-from-enGB", section = "char", setup = function()
        WowStub.state.region, WowStub.state.locale = 90, "enGB" -- no /rl region: guessed eu
    end },
    { name = "guild-small-single-page", section = "guild", setup = function() end },
    { name = "guild-notes-on", section = "guild", setup = function(ns) ns.HandleSlash("guildnotes on") end },
    { name = "guild-600-3pages", section = "guild", reversed = true,
        setup = function() WowStub.state.guildRoster = WowStub.roster(600) end },
    { name = "guild-2000-8pages", section = "guild", reversed = true,
        setup = function() WowStub.state.guildRoster = WowStub.roster(2000) end },
    { name = "guild-2100-capped", section = "guild",
        setup = function() WowStub.state.guildRoster = WowStub.roster(2100) end },
    { name = "raid-1-pull", section = "raid", setup = function(ns) raidPulls(ns, 1, 40) end },
    -- "Export all" (ROK-1737): one paste, one string per section, one per line.
    { name = "all-char-guild-raid", section = "all", setup = function(ns) raidPulls(ns, 3, 25) end },
    { name = "all-char-guild3-raid", section = "all", setup = function(ns)
        WowStub.state.guildRoster = WowStub.roster(600)
        raidPulls(ns, 2, 40)
    end },
    { name = "all-char-only", section = "all", setup = function() WowStub.state.guild = nil end },
    { name = "raid-50-pulls-ring-full", section = "raid", setup = function(ns) raidPulls(ns, 60, 40) end },
}

-- Returns the export pages (strings) for one case, from a freshly loaded addon.
-- For "all" these are the paste's tokens (char, guild pages, raid).
local function run(case)
    local ns = loadAddon()
    case.setup(ns)
    if case.section == "all" then return assert(ns.Export.RunAll()) end
    return assert(ns.Export.RunPages(case.section))
end

return { cases = cases, run = run }
