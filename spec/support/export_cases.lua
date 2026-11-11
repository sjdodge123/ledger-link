-- Export scenarios shared by spec/contract_spec.lua and tools/gen_strings.lua:
-- char (rulesets, empty/nil data, urlsafe client base64), guild (single, notes,
-- 3 and 8 pages, capped), raid (1 pull, ring buffer full). `reversed` marks
-- paged cases that are also checked with the pages pasted in reverse order.
local loadAddon = require("spec.support.load_addon")
local seedPulls = require("spec.support.seed_pulls")

-- The Mailworthy addon's API returning a golden fixture's block
-- (contract/v1/fixtures/<name>.json, payload.mailworthy); returns the block.
local function mailworthyFixture(name)
    local dkjson = require("dkjson")
    local f = assert(io.open("contract/v1/fixtures/" .. name .. ".json"))
    local block = assert(dkjson.decode(f:read("*a")).payload.mailworthy, name .. " has no mailworthy block")
    f:close()
    _G.MailworthyAPI = { v1 = { GetGuildExport = function() return block end } }
    return block
end

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
    { name = "char-rppvp", section = "char", setup = function(ns) ns.HandleSlash("ruleset rppvp") end },
    { name = "char-rppvp-detected", section = "char",
        setup = function() WowStub.state.realmName = "CAMWOW US2 Realm 9 RP PvP" end },
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
    -- Phase 2 (ROK-1742): gender, every talent node positioned + named, quests.
    { name = "char-forever-phase2", section = "char", setup = function()
        local st = WowStub.state
        _G.UnitSex = function() return 3 end
        st.talentTrees = { [1117] = {} }
        st.talentNodes = {}
        local cols = { 1020, 1620, 2220, 2820, 5020, 5620, 6220, 6820, 9080, 9680, 10280, 10880 }
        for i = 1, 52 do
            local id = 105900 + i
            st.talentTrees[1117][i] = id
            st.talentNodes[id] = { activeRank = i == 1 and 1 or 0, maxRanks = (i % 5) + 1, entryIDs = { 130600 + i },
                posX = cols[(i % 12) + 1] + (i == 7 and 10 or 0), posY = 2130 + 600 * (i % 7) }
        end
        _G.C_Traits.GetEntryInfo = function(_, e) return { definitionID = e + 4801 } end
        _G.C_Traits.GetDefinitionInfo = function(d) return { spellID = d - 115000 } end
        _G.C_Spell = { GetSpellName = function(id) return "Talent " .. id end }
        local done = {}
        for i = 1, 75 do done[i] = 6 + i * 7 end
        _G.C_QuestLog = {
            GetAllCompletedQuestIDs = function() return done end,
            GetNumQuestLogEntries = function() return 3, 2 end,
            GetInfo = function(i)
                return ({ { title = "Elwynn Forest", isHeader = true },
                    { questID = 60, title = "Kobold Candles" }, { questID = 98391, title = "The Sisterhood of Elune" } })[i]
            end,
            GetQuestObjectives = function(id)
                if id == 60 then
                    return { { text = "7/8 Large Candle", finished = false, numFulfilled = 7, numRequired = 8 } }
                end
                return {}
            end,
        }
    end },
    -- ROK-2148: the Mailworthy guild contributions block, from the golden fixtures.
    { name = "char-mailworthy", section = "char", setup = function() mailworthyFixture("char-mailworthy") end },
    { name = "char-mailworthy-template-only", section = "char",
        setup = function() mailworthyFixture("char-mailworthy-template-only") end },
    { name = "all-char-mailworthy-guild-raid", section = "all", setup = function(ns)
        mailworthyFixture("char-mailworthy")
        raidPulls(ns, 1, 25)
    end },
    { name = "guild-small-single-page", section = "guild", setup = function() end },
    { name = "guild-notes-on", section = "guild", setup = function(ns) ns.HandleSlash("guildnotes on") end },
    { name = "guild-600-3pages", section = "guild", reversed = true,
        setup = function() WowStub.state.guildRoster = WowStub.roster(600) end },
    { name = "guild-2000-8pages", section = "guild", reversed = true,
        setup = function() WowStub.state.guildRoster = WowStub.roster(2000) end },
    { name = "guild-2100-capped", section = "guild",
        setup = function() WowStub.state.guildRoster = WowStub.roster(2100) end },
    -- ROK-2137: the in-game Message of the Day / Guild Information. Every guild
    -- case above carries both boxes; these are the empty, unreadable and
    -- over-length ones (clipped to 255 / 499 UTF-16 units).
    { name = "guild-text-empty-boxes", section = "guild",
        setup = function() WowStub.state.guildMotd, WowStub.state.guildInfoText = "", "" end },
    { name = "guild-text-unreadable", section = "guild",
        setup = function() WowStub.state.guildMotd, WowStub.state.guildInfoText = nil, nil end },
    { name = "guild-text-over-length", section = "guild", setup = function()
        WowStub.state.guildMotd = string.rep("\195\169", 300)
        WowStub.state.guildInfoText = "x" .. string.rep("\240\159\148\165", 300)
    end },
    { name = "raid-1-pull", section = "raid", setup = function(ns) raidPulls(ns, 1, 40) end },
    -- "Export all" (ROK-1737): one paste, one string per section, one per line.
    { name = "all-char-guild-raid", section = "all", setup = function(ns) raidPulls(ns, 3, 25) end },
    { name = "all-char-guild3-raid", section = "all", setup = function(ns)
        WowStub.state.guildRoster = WowStub.roster(600)
        raidPulls(ns, 2, 40)
    end },
    { name = "all-char-only", section = "all", setup = function() WowStub.state.guild = nil end },
    -- The logout auto-export: guild roster, gear and talents read while playing,
    -- then the client drops them at PLAYER_LOGOUT (2026-11-07 bug).
    { name = "all-logout-from-cache", section = "all", setup = function(ns)
        raidPulls(ns, 1, 25)
        ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
        ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
        ns.Guild.OnEvent("PLAYER_LEAVING_WORLD")
        ns.Char.OnEvent("PLAYER_LEAVING_WORLD")
        local s = WowStub.state
        s.guild, s.guildRoster, s.gear, s.talentConfigId = nil, {}, {}, nil
    end },
    { name = "raid-50-pulls-ring-full", section = "raid", setup = function(ns) raidPulls(ns, 60, 40) end },
    -- ROK-2123: an account whose SavedVariables hold 250 pulls, 40 distinct players each.
    { name = "raid-250-stored-pulls-newest", section = "raid",
        setup = function() LedgerLinkDB.raid = { pulls = seedPulls(250) } end },
    { name = "raid-300-stored-pulls-capped-200", section = "raid", setup = function(ns)
        ns.Raid.MAX_PULLS = 300 -- a ring buffer past the contract cap: the export stops at the newest 200
        LedgerLinkDB.raid = { pulls = seedPulls(300) }
    end },
}

-- Returns the export pages (strings) for one case, from a freshly loaded addon.
-- For "all" these are the paste's tokens (char, guild pages, raid).
local function run(case)
    local ns = loadAddon()
    case.setup(ns)
    if case.section == "all" then return assert(ns.Export.RunAll()) end
    return assert(ns.Export.RunPages(case.section))
end

return { cases = cases, run = run, mailworthyFixture = mailworthyFixture }
