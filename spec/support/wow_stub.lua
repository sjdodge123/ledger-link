-- Stubs for every WoW API LedgerLink calls. `WowStub.reset()` restores the
-- default player; tests tweak `WowStub.state` before calling the addon.
-- C_EncodingUtil is backed by LibDeflate (real zlib) + pure-Lua base64, so
-- strings produced under test are real strings the Raid Ledger decoder reads.
local LibDeflate = require("LibDeflate")
local base64 = require("spec.support.base64")

local WowStub = {}
_G.WowStub = WowStub

local function defaultState()
    return {
        guid = "Player-4395-0ABCDEF0",
        unitName = { "Ana" },
        unitFullName = { "Ana", "Forever" },
        getUnitName = "Ana Forever",
        realmName = "Forever",
        region = 1,
        build = { "1.60.1", "70009", "Sep 30 2026", 16001 },
        locale = "enUS",
        class = { "Paladin", "PALADIN", 2 },
        race = { "Human", "Human", 1 },
        level = 60,
        faction = "Alliance",
        guild = "Night Shift",
        serverTime = 1790000000,
        inCombat = false,
        gear = {
            [1] = { id = 16921, link = "|cffa335ee|Hitem:16921::::::::60:::::|h[Halo of Transcendence]|h|r", ilvl = 76 },
            [16] = { id = 19019, link = "|cffff8000|Hitem:19019:0:0:0:0:0:0:0:60:0:0:0:2:6646:7890|h[Thunderfury]|h|r", ilvl = 80 },
        },
        talentConfigId = 7,
        talentImportString = "BkAAAAAAAAAAAAAAAAAAAAAAAA",
        talentTrees = { [42] = { 101, 102, 103 } },
        talentNodes = {
            [101] = { activeRank = 2, activeEntry = { entryID = 9001 } },
            [102] = { activeRank = 0 },
            [103] = { ranksPurchased = 1 },
        },
        lockouts = {
            { "Molten Core", 1, 3600, 9, true, false, 0, true, 40, "40 Player", 10, 3, false, 409 },
            { "Expired", 2, 0, 9, false, false, 0, true, 40, "40 Player", 10, 10, false, 249 },
        },
        base64Variant = "standard",
        -- guild: GetGuildRosterInfo tuples (17 returns, slot 8 = officer note)
        guildRealm = nil,
        guildRoster = {
            WowStub.member(0, { guid = "Player-4395-0ABCDEF0", name = "Ana Forever-Forever", online = true }),
            WowStub.member(1),
            WowStub.member(2, { rankIndex = 0, rank = "Guild Master" }),
        },
        lastOnline = {},
        rosterRequests = 0,
        -- raid / group
        inRaid = false,
        numGroupMembers = 0,
        units = {},
        instance = { "Molten Core", "raid", 9, "40 Player", 40, 0, false, 409 },
    }
end

--- One GetGuildRosterInfo tuple. Slot 8 always holds an officer note so
--- tests prove it never leaves the addon.
function WowStub.member(i, o)
    o = o or {}
    local hex = string.format("%08X", 0x10000 + i)
    local online = o.online or false
    return {
        o.name or ("Member" .. i .. " Surname-Forever"), o.rank or "Raider", o.rankIndex or 3, o.level or 60,
        "Mage", "Orgrimmar", o.note or ("public note " .. i), o.officerNote or ("OFFICER SECRET " .. i),
        online, 0, o.class or "MAGE", 0, 0, false, false, 0, o.guid or ("Player-4395-" .. hex),
    }
end

--- `n` roster rows with distinct GUIDs (the exporter is row 1).
function WowStub.roster(n)
    local rows = { WowStub.member(0, { guid = "Player-4395-0ABCDEF0", name = "Ana Forever-Forever", online = true }) }
    for i = 1, n - 1 do rows[#rows + 1] = WowStub.member(i) end
    return rows
end

--- Put `n` members in the player's raid (raid1 = the player).
function WowStub.raid(n)
    local st = WowStub.state
    st.inRaid, st.numGroupMembers, st.units = true, n, {}
    for i = 1, n do
        local guid = i == 1 and st.guid or string.format("Player-4395-%08X", 0x20000 + i)
        st.units["raid" .. i] = { guid = guid, name = i == 1 and st.getUnitName or ("Raider" .. i .. " Doe") }
    end
end

local printed = {}
WowStub.printed = printed

function WowStub.reset()
    WowStub.state = defaultState()
    for i = #printed, 1, -1 do printed[i] = nil end
    _G.LedgerLinkDB, _G.LedgerLinkCharDB = nil, nil
end
WowStub.reset()

local function s() return WowStub.state end

_G.unpack = _G.unpack or table.unpack -- luacheck: ignore 143
_G.time = os.time
_G.date = os.date
_G.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
    printed[#printed + 1] = table.concat(t, " ")
end
local function unit(u)
    if u == nil or u == "player" then return { guid = s().guid, name = s().getUnitName } end
    return s().units[u]
end
_G.UnitGUID = function(u)
    local x = unit(u)
    if x and x.secret then error("attempt to use a secret value") end
    return x and x.guid
end
_G.UnitName = function() return unpack(s().unitName, 1, 2) end
_G.UnitFullName = function() return unpack(s().unitFullName, 1, 2) end
_G.GetUnitName = function(u) local x = unit(u) return x and x.name end
_G.GetRealmName = function() return s().realmName end
_G.GetCurrentRegion = function() return s().region end
_G.GetBuildInfo = function() return unpack(s().build, 1, 4) end
_G.GetLocale = function() return s().locale end
_G.UnitClass = function() return unpack(s().class, 1, 3) end
_G.UnitRace = function() return unpack(s().race, 1, 3) end
_G.UnitLevel = function() return s().level end
_G.UnitFactionGroup = function() return s().faction end
_G.GetGuildInfo = function() return s().guild, "Raider", 3, s().guildRealm end
_G.GetNumGuildMembers = function() return #s().guildRoster, 0, 0 end
_G.GetGuildRosterInfo = function(i) local r = s().guildRoster[i] if r then return unpack(r, 1, 17) end end
_G.GetGuildRosterLastOnline = function(i) return unpack(s().lastOnline[i] or { 0, 0, 2, 5 }, 1, 4) end
_G.C_GuildInfo = { GuildRoster = function() s().rosterRequests = s().rosterRequests + 1 end }
_G.GetNumGroupMembers = function() return s().numGroupMembers end
_G.IsInRaid = function() return s().inRaid end
_G.GetInstanceInfo = function() return unpack(s().instance, 1, 8) end
_G.GetServerTime = function() return s().serverTime end
_G.InCombatLockdown = function() return s().inCombat end
_G.GetInventoryItemLink = function(_, slot) local g = s().gear[slot] return g and g.link end
_G.GetInventoryItemID = function(_, slot) local g = s().gear[slot] return g and g.id end
_G.C_Item = {
    GetDetailedItemLevelInfo = function(link)
        for _, g in pairs(s().gear) do if g.link == link then return g.ilvl, false, g.ilvl end end
    end,
}
_G.C_ClassTalents = { GetActiveConfigID = function() return s().talentConfigId end }
_G.C_Traits = {
    GenerateImportString = function() return s().talentImportString end,
    GetConfigInfo = function()
        local ids = {}
        for treeId in pairs(s().talentTrees) do ids[#ids + 1] = treeId end
        return { treeIDs = ids }
    end,
    GetTreeNodes = function(treeId) return s().talentTrees[treeId] end,
    GetNodeInfo = function(_, nodeId) return s().talentNodes[nodeId] end,
}
_G.GetNumSavedInstances = function() return #s().lockouts end
_G.GetSavedInstanceInfo = function(i) return unpack(s().lockouts[i], 1, 14) end

_G.Enum = {
    CompressionMethod = { Deflate = 0, Zlib = 1, Gzip = 2 },
    CompressionLevel = { Default = 0, OptimizeForSpeed = 1, OptimizeForSize = 2 },
}
_G.C_EncodingUtil = {
    CompressString = function(source, method)
        assert(method == Enum.CompressionMethod.Zlib, "LedgerLink must use Zlib")
        return LibDeflate:CompressZlib(source, { level = 9 })
    end,
    DecompressString = function(source) return LibDeflate:DecompressZlib(source) end,
    EncodeBase64 = function(source)
        local b64 = base64.encode(source)
        if s().base64Variant == "urlsafe-unpadded" then
            b64 = b64:gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
        end
        return b64
    end,
    DecodeBase64 = function(source) return base64.decode(source) end,
}

-- Widget stubs: any method call is accepted and recorded.
local function newWidget(kind, name)
    local w = { kind = kind, name = name, scripts = {}, shown = false, events = {} }
    return setmetatable(w, { __index = function(self, key)
        if key == "SetScript" then return function(_, ev, fn) self.scripts[ev] = fn end end
        if key == "RegisterEvent" then return function(_, ev) self.events[ev] = true end end
        if key == "SetText" then return function(_, t) self.text = t end end
        if key == "GetText" then return function() return self.text end end
        if key == "Show" then return function() self.shown = true end end
        if key == "Hide" then return function() self.shown = false end end
        if key == "CreateFontString" then return function() return newWidget("FontString") end end
        return function() end
    end })
end
WowStub.frames = {}
_G.CreateFrame = function(kind, name)
    local w = newWidget(kind, name)
    if name then WowStub.frames[name] = w; _G[name] = w end
    return w
end
_G.UIParent = newWidget("Frame", "UIParent")
_G.UISpecialFrames = {}
_G.ChatFontNormal = {}
_G.SlashCmdList = {}

return WowStub
