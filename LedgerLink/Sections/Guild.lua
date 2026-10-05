-- Guild roster export (`!RL1!guild!...`, or `!RL1!guild-<n>of<m>!...` pages).
-- Contract: AddonGuildDataSchema / AddonGuildMemberSchema (strict).
-- The officer note is NEVER read, let alone exported (operator ruling Q4/Q6).
local _, ns = ...

local Json = ns.Json
local Guild = {}
ns.Guild = Guild

--- Contract AddonGuildDataSchema.members max (also the server merge cap).
Guild.MAX_MEMBERS = 2000
--- Members per page: 2000 / 250 = 8 pages = server ADDON_IMPORT_MAX_PAGES.
Guild.MEMBERS_PER_PAGE = 250
--- Defensive loop bound if GetNumGuildMembers returns something absurd.
local MAX_ROSTER_SCAN = 10000
local MAX_NOTE = 256

-- GetGuildRosterInfo(i), retail order (UNVERIFIED on Forever, beta E1):
--  1 name  2 rankName  3 rankIndex  4 level  5 classDisplayName  6 zone
--  7 publicNote  8 officerNote (NEVER read)  9 isOnline  10 status
--  11 classFileName  12-16 (unused)  17 guid
local R_NAME, R_RANK, R_RANK_INDEX, R_LEVEL, R_NOTE, R_ONLINE, R_CLASS, R_GUID = 1, 2, 3, 4, 7, 9, 11, 17

local function rosterCount()
    local n = ns.AsId(ns.SafeCall(GetNumGuildMembers)) or 0
    return math.min(n, MAX_ROSTER_SCAN)
end


local function lastOnlineDays(i, online)
    if online then return nil end
    local years, months, days = ns.SafeCall(GetGuildRosterLastOnline, i)
    if type(years) ~= "number" and type(months) ~= "number" and type(days) ~= "number" then return nil end
    return ns.AsId((tonumber(years) or 0) * 365 + (tonumber(months) or 0) * 30 + (tonumber(days) or 0))
end

local function validClass(class)
    return type(class) == "string" and #class <= 16 and string.match(class, "^%u%u+$") ~= nil
end

--- One strict member row, or nil when a required field is unreadable.
--- Keys are exactly the contract's; the roster tuple's slot 8 is never touched.
function Guild.MemberRow(i, includeNotes)
    local r = { ns.SafeCall(GetGuildRosterInfo, i) }
    local guid = ns.NormalizeGuid(r[R_GUID])
    local level, rankIndex = ns.AsId(r[R_LEVEL]), ns.AsId(r[R_RANK_INDEX])
    if not guid or not validClass(r[R_CLASS]) then return nil end
    if not level or level < 1 or level > 100 or not rankIndex or rankIndex > 255 then return nil end
    local online = r[R_ONLINE] == true or r[R_ONLINE] == 1
    local row = {
        guid = guid,
        name = ns.Clip(r[R_NAME], 100) or "",
        rankIndex = rankIndex,
        rank = ns.Clip(r[R_RANK], 64) or "",
        level = level,
        class = r[R_CLASS],
        online = online,
        lastOnlineDays = lastOnlineDays(i, online),
    }
    local note = includeNotes and ns.Clip(r[R_NOTE], MAX_NOTE) or nil
    if note and note ~= "" then row.note = note end
    return row
end

--- Over the cap: keep the exporter (the server requires them), then online
--- members, then the most recently seen. Stable on roster order.
local function capMembers(members, selfGuid)
    if #members <= Guild.MAX_MEMBERS then return members, 0 end
    for i, m in ipairs(members) do m._order = i end
    table.sort(members, function(a, b)
        local aSelf, bSelf = a.guid == selfGuid, b.guid == selfGuid
        if aSelf ~= bSelf then return aSelf end
        if a.online ~= b.online then return a.online end
        local ad, bd = a.lastOnlineDays or 0, b.lastOnlineDays or 0
        if ad ~= bd then return ad < bd end
        return a._order < b._order
    end)
    local kept = Json.array()
    for i = 1, Guild.MAX_MEMBERS do kept[i] = members[i] end
    for _, m in ipairs(members) do m._order = nil end
    return kept, #members - Guild.MAX_MEMBERS
end

local function report(skipped, dupes, omitted)
    if skipped > 0 then ns.Print(skipped .. " roster row(s) were unreadable and skipped.") end
    if dupes > 0 then ns.Print(dupes .. " duplicate roster row(s) were dropped.") end
    if omitted > 0 then
        ns.Print(string.format("Your guild has more than %d members: %d long-offline member(s) were left out.",
            Guild.MAX_MEMBERS, omitted))
    end
end

local function collectMembers(includeNotes)
    local members, seen, skipped, dupes = Json.array(), {}, 0, 0
    for i = 1, rosterCount() do
        local row = Guild.MemberRow(i, includeNotes)
        if not row then
            skipped = skipped + 1
        elseif seen[row.guid] then
            dupes = dupes + 1
        else
            seen[row.guid] = true
            members[#members + 1] = row
        end
    end
    return members, skipped, dupes
end

function Guild.Build()
    local name, _, _, realm = ns.SafeCall(GetGuildInfo, "player")
    name = ns.Clip(name, 64)
    if not name or name == "" then return nil, "You're not in a guild." end
    if rosterCount() == 0 then
        return nil, "The guild roster hasn't loaded yet - wait a few seconds and run /rl export guild again."
    end
    local includeNotes = type(LedgerLinkDB) == "table" and LedgerLinkDB.guildNotes == true
    local members, skipped, dupes = collectMembers(includeNotes)
    local omitted
    members, omitted = capMembers(members, ns.NormalizeGuid(ns.SafeCall(UnitGUID, "player")))
    report(skipped, dupes, omitted)
    if #members == 0 then return nil, "No readable guild members. Please report this." end
    local rawRealm = ns.Clip(realm, 64) or ns.Clip(ns.SafeCall(GetRealmName), 64)
    return {
        name = name,
        rawRealm = rawRealm ~= "" and rawRealm or nil,
        snapshotAt = math.floor(ns.SafeCall(GetServerTime) or time()),
        canViewOfficerNote = false, -- always: officer notes are never exported
        members = members,
    }
end

--- Split `data.members` into pages of MEMBERS_PER_PAGE. Every page repeats
--- name / rawRealm / snapshotAt / canViewOfficerNote (the server checks them).
function Guild.Paginate(data)
    local per = Guild.MEMBERS_PER_PAGE
    local count = math.max(1, math.ceil(#data.members / per))
    if count == 1 then return { data } end
    local chunks = {}
    for p = 1, count do
        local slice = Json.array()
        for i = (p - 1) * per + 1, math.min(p * per, #data.members) do slice[#slice + 1] = data.members[i] end
        chunks[p] = {
            name = data.name, rawRealm = data.rawRealm, snapshotAt = data.snapshotAt,
            canViewOfficerNote = false, members = slice,
        }
    end
    return chunks
end

local pending

--- Export now if the client has the roster, else on the next
--- GUILD_ROSTER_UPDATE. The addon never requests the roster itself: on the
--- beta, C_GuildInfo.GuildRoster() from an addon raised "blocked from an action
--- only available to the Blizzard UI" (2026-10-05). Opening the Guild window
--- makes the game load it.
function Guild.Prepare(done)
    if rosterCount() > 0 or not ns.SafeCall(GetGuildInfo, "player") then
        done()
        return
    end
    pending = done
    ns.Print("The guild roster isn't loaded yet: open the Guild window (J) and the export will open.")
end

function Guild.OnEvent(event)
    if event == "GUILD_ROSTER_UPDATE" and pending then
        local done = pending
        pending = nil
        done()
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("GUILD_ROSTER_UPDATE")
events:SetScript("OnEvent", function(_, event) Guild.OnEvent(event) end)

ns.Export.RegisterSection("guild", Guild.Build, { paginate = Guild.Paginate, prepare = Guild.Prepare })
