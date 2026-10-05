-- Boss-pull export (`!RL1!raid!...`). Contract: AddonRaidDataSchema.
--
-- ENCOUNTER_START / ENCOUNTER_END are recorded into a ring buffer in
-- LedgerLinkDB.raid.pulls (the newest Raid.MAX_PULLS pulls survive). Each pull
-- carries the group roster (<= 40 GUIDs + names) read at the pull.
-- No combat log: COMBAT_LOG_EVENT_UNFILTERED is unavailable on Forever, so
-- there is no damage data and Details!/DBM-style CLEU parsing is impossible
-- (spike 2026-10-04 §1). Unit GUIDs/names may be secret values during an
-- encounter (beta E5): every unit read is pcall-wrapped and retried at END.
local _, ns = ...

local Json = ns.Json
local Raid = {}
ns.Raid = Raid

--- Ring-buffer cap (spike: "last 50 pulls"; contract allows 200).
Raid.MAX_PULLS = 50
--- Contract AddonPullSchema.roster / rosterNames max.
Raid.MAX_ROSTER = 40
--- Contract unixSeconds ceiling (2100-01-01): anything larger is milliseconds.
local UNIX_SECONDS_MAX = 4102444800

local function store()
    if type(LedgerLinkDB) ~= "table" then LedgerLinkDB = {} end
    local r = LedgerLinkDB.raid
    if type(r) ~= "table" then
        r = {}
        LedgerLinkDB.raid = r
    end
    if type(r.pulls) ~= "table" then r.pulls = {} end
    return r
end

function Raid.Pulls() return store().pulls end

--- Unix seconds from the server clock (a millisecond clock is divided down).
function Raid.Now()
    local t = ns.SafeCall(GetServerTime)
    if type(t) ~= "number" or t ~= t or t <= 0 then t = time() end
    if t > UNIX_SECONDS_MAX then t = t / 1000 end
    return math.floor(t)
end

local function groupUnits()
    local n = ns.AsId(ns.SafeCall(GetNumGroupMembers)) or 0
    local units = {}
    if ns.SafeCall(IsInRaid) then
        for i = 1, math.min(n, Raid.MAX_ROSTER) do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, math.min(math.max(n - 1, 0), 4) do units[#units + 1] = "party" .. i end
    end
    return units
end

local function readUnit(unit)
    local ok, guid, name = pcall(function()
        local g = ns.NormalizeGuid(UnitGUID(unit))
        local nm = GetUnitName(unit, true)
        return g, ns.Clip(nm, 100)
    end)
    if ok then return guid, name end
    return nil
end

--- Group roster now: unique GUIDs (<= 40) and their names, in the same order.
function Raid.Roster()
    local roster, names, seen = {}, {}, {}
    for _, unit in ipairs(groupUnits()) do
        if #roster >= Raid.MAX_ROSTER then break end
        local guid, name = readUnit(unit)
        if guid and not seen[guid] then
            seen[guid] = true
            roster[#roster + 1] = guid
            names[#names + 1] = name or ""
        end
    end
    return roster, names
end

local function newPull(encounterId, name, difficultyId, groupSize)
    local _, _, _, _, _, _, _, instanceId = ns.SafeCall(GetInstanceInfo)
    local roster, names = Raid.Roster()
    return {
        encounterId = encounterId,
        name = ns.Clip(name, 128) or "",
        difficultyId = ns.AsId(difficultyId) or 0,
        groupSize = ns.AsId(groupSize),
        instanceId = ns.AsId(instanceId),
        startAt = Raid.Now(),
        roster = roster,
        rosterNames = names,
    }
end

function Raid.Start(encounterId, name, difficultyId, groupSize)
    local id = ns.AsId(encounterId)
    if not id then return end
    store().current = newPull(id, name, difficultyId, groupSize)
end

local function push(pulls, pull)
    pulls[#pulls + 1] = pull
    while #pulls > Raid.MAX_PULLS do table.remove(pulls, 1) end
end

function Raid.End(encounterId, name, difficultyId, groupSize, success)
    local id = ns.AsId(encounterId)
    if not id then return end
    local r = store()
    local pull = r.current
    r.current = nil
    -- END without a matching START (a /reload mid-pull): record from END.
    if type(pull) ~= "table" or pull.encounterId ~= id then pull = newPull(id, name, difficultyId, groupSize) end
    if #pull.roster == 0 then pull.roster, pull.rosterNames = Raid.Roster() end
    pull.endAt = math.max(Raid.Now(), pull.startAt)
    pull.success = success == 1 or success == true
    push(r.pulls, pull)
end

function Raid.OnEvent(event, ...)
    if event == "ENCOUNTER_START" then
        Raid.Start(...)
    elseif event == "ENCOUNTER_END" then
        Raid.End(...)
    end
end

function Raid.Clear()
    local r = store()
    r.pulls, r.current = {}, nil
end

local function seconds(v)
    local n = ns.AsId(v)
    if n and n > 0 and n <= UNIX_SECONDS_MAX then return n end
    return nil
end

-- SavedVariables drop metatables (and may be stale or hand-edited), so each
-- stored pull is re-validated and rebuilt with Json.array lists on export.
local function exportRow(p)
    if type(p) ~= "table" or not ns.AsId(p.encounterId) then return nil end
    local startAt, endAt = seconds(p.startAt), seconds(p.endAt)
    if not startAt or not endAt then return nil end
    local roster, names = Json.array(), Json.array()
    local storedNames = type(p.rosterNames) == "table" and p.rosterNames or {}
    for i, guid in ipairs(type(p.roster) == "table" and p.roster or {}) do
        if #roster >= Raid.MAX_ROSTER then break end
        local g = ns.NormalizeGuid(guid)
        if g then
            roster[#roster + 1] = g
            names[#names + 1] = ns.Clip(storedNames[i], 100) or ""
        end
    end
    local size = ns.AsId(p.groupSize)
    if not size or size < 1 then size = math.max(#roster, 1) end
    return {
        encounterId = ns.AsId(p.encounterId),
        name = ns.Clip(p.name, 128) or "",
        difficultyId = ns.AsId(p.difficultyId) or 0,
        groupSize = math.min(size, 40),
        instanceId = ns.AsId(p.instanceId),
        startAt = startAt,
        endAt = math.max(endAt, startAt),
        success = p.success == true,
        roster = roster,
        rosterNames = names,
    }
end

function Raid.Build()
    local pulls = Json.array()
    for _, p in ipairs(store().pulls) do
        local row = exportRow(p)
        if row and #pulls < Raid.MAX_PULLS then pulls[#pulls + 1] = row end
    end
    if #pulls == 0 then
        return nil, "No boss pulls recorded yet. Ledger Link records a pull at every boss ENCOUNTER_START/END."
    end
    return { pulls = pulls }
end

local events = CreateFrame("Frame")
events:RegisterEvent("ENCOUNTER_START")
events:RegisterEvent("ENCOUNTER_END")
events:SetScript("OnEvent", function(_, event, ...) Raid.OnEvent(event, ...) end)

ns.Export.RegisterSection("raid", Raid.Build)
