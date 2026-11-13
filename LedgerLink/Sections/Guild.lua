-- Guild roster export (`!RL1!guild!...`, or `!RL1!guild-<n>of<m>!...` pages).
-- Contract: AddonGuildDataSchema / AddonGuildMemberSchema (strict).
-- The officer note is NEVER read, let alone exported (operator ruling Q4/Q6).
-- The Message of the Day and Guild Information boxes (`motd`, `infoText`,
-- Raid Ledger ROK-2137) are the guild's public text: every member reads them.
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
--- Contract AddonGuildDataSchema.motd / .infoText max, in UTF-16 units.
Guild.MAX_MOTD, Guild.MAX_INFO_TEXT = 255, 499

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

-- One in-game text box as `readGuildText` returns it, clipped to `max` UTF-16
-- units and otherwise verbatim (colour codes and newlines kept). Errors on
-- anything odd. (A blocked call is reported under this local's name.)
local function boxText(readGuildText, max)
    local text = readGuildText()
    -- A secret value can't be measured or encoded: treat it as unreadable.
    if type(issecretvalue) == "function" and issecretvalue(text) then return nil end
    return ns.ClipUtf16(text, max)
end

--- After a guild text read is blocked, no read is tried for this long.
Guild.TEXT_RETRY_SECONDS = 300
local textBlockedAt

-- "" = the box is empty; nil = could not read it (the key is then left out,
-- which Raid Ledger takes as "no opinion"). Never "" for a failed read.
-- Forever's own Guild window reads C_GuildInfo.GetMOTD / GetInfoText; the
-- pre-12.0 globals are only aliases the client defines when the
-- loadDeprecationFallbacks CVar is on (Blizzard_DeprecatedGuildScript).
-- Both reads are HasRestrictions APIs: while the game enforces an addon
-- restriction (combat, an encounter, a restricted map, chat lockdown) it blocks
-- them with ADDON_ACTION_BLOCKED "read()" (2026-11-11, background refreshes).
-- Second return: true when the game blocked the read.
local function readBox(method, legacy, max)
    local api = type(C_GuildInfo) == "table" and C_GuildInfo or {}
    for _, readGuildText in ipairs({ api[method] or false, _G[legacy] or false }) do
        local blocksBefore = ns.Blocked.count
        local text = type(readGuildText) == "function" and ns.SafeCall(boxText, readGuildText, max) or nil
        if ns.Blocked.count > blocksBefore then
            textBlockedAt = ns.SafeCall(GetServerTime) or time()
            return nil, true -- the alias is the same API: don't trip it too
        end
        if text then return text end
    end
    return nil
end

-- Whether to try the guild text reads now: no addon restriction is on and no
-- read was blocked in the last TEXT_RETRY_SECONDS.
local function textReadable()
    if #ns.Blocked.ActiveRestrictions() > 0 then return false end
    local now = ns.SafeCall(GetServerTime) or time()
    return not textBlockedAt or now - textBlockedAt >= Guild.TEXT_RETRY_SECONDS
end

local function inGuildNow()
    local inGuild = ns.SafeCall(IsInGuild)
    if inGuild == nil then inGuild = ns.SafeCall(GetGuildInfo, "player") end
    return inGuild ~= nil and inGuild ~= false
end

local function liveName()
    local name = ns.Clip(ns.SafeCall(GetGuildInfo, "player"), 64)
    if name and name ~= "" then return name end
    return nil
end

-- Whether the server has sent this guild's text this session. Until it has,
-- GetMOTD / GetInfoText read "" (2026-11-13: during a Blizzard outage an
-- export sent motd = "" and infoText = "" and Raid Ledger wiped the guild's
-- stored text), so both keys are left out. Set by GUILD_MOTD (any text, ""
-- included: an officer cleared it) or by a GUILD_ROSTER_UPDATE with a
-- populated roster, while IsInGuild() and GetGuildInfo("player") names the
-- guild. A GUILD_ROSTER_UPDATE with an empty roster or leaving the guild clears
-- it; so does a different guild name. Never persisted: a /reload or a relog
-- (after a disconnect) starts unloaded.
local textLoadedFor, textLoadedBy

local function markTextLoaded(signal)
    local name = inGuildNow() and liveName() or nil
    if name then textLoadedFor, textLoadedBy = name, signal end
end

local function textLoaded(guildName)
    return textLoadedFor ~= nil and textLoadedFor == guildName and inGuildNow()
end

--- `/rl probe` line: whether the guild text gate is open, and what opened it.
function Guild.TextStateLine()
    local name = liveName()
    if name and textLoaded(name) then return "guild text: loaded (" .. textLoadedBy .. ")" end
    return "guild text: not loaded (motd / infoText left out until GUILD_MOTD or a populated GUILD_ROSTER_UPDATE)"
end

-- Between PLAYER_LEAVING_WORLD and PLAYER_ENTERING_WORLD (loading screen or
-- logout) the guild APIs may read "no guild": that is not leaving it.
local leavingWorld = false

-- motd, infoText: read now when the text has loaded and reads are allowed. A
-- box not read (not loaded yet, a restriction or a block) keeps the text last
-- read for this guild this session; a read that ran and failed leaves it out
-- (see readBox). While leaving the world (logout, or a disconnect) a "" read
-- is not trusted either: it keeps the text last read, or is left out.
local function readBoxes(guildName)
    local motd, infoText
    local motdTried, infoTried = false, false
    if textLoaded(guildName) and textReadable() then
        local blocked
        motd, blocked = readBox("GetMOTD", "GetGuildRosterMOTD", Guild.MAX_MOTD)
        motdTried = not blocked
        if not blocked then
            infoText, blocked = readBox("GetInfoText", "GetGuildInfoText", Guild.MAX_INFO_TEXT)
            infoTried = not blocked
        end
    end
    local last = Guild.cache
    if last and last.name == guildName then
        if not motdTried then motd = last.motd end
        if not infoTried then infoText = last.infoText end
    end
    if leavingWorld then
        if motd == "" then motd = last and last.name == guildName and last.motd or nil end
        if infoText == "" then infoText = last and last.name == guildName and last.infoText or nil end
    end
    return motd, infoText
end

-- The roster as read right now; nil + a message when the client can't give it.
-- `quiet` skips the chat report (the background refresh below).
local function buildLive(quiet)
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
    if not quiet then report(skipped, dupes, omitted) end
    if #members == 0 then return nil, "No readable guild members. Please report this." end
    local rawRealm = ns.Clip(realm, 64) or ns.Clip(ns.SafeCall(GetRealmName), 64)
    local motd, infoText = readBoxes(name)
    return {
        name = name,
        rawRealm = rawRealm ~= "" and rawRealm or nil,
        snapshotAt = math.floor(ns.SafeCall(GetServerTime) or time()),
        canViewOfficerNote = false, -- always: officer notes are never exported
        members = members,
        motd = motd,
        infoText = infoText,
    }
end

-- Roster cache for the logout auto-export (Outbox.lua). At PLAYER_LOGOUT the
-- client has already dropped the guild: GetGuildInfo("player") returns nil and
-- the roster is empty, so every logout export lost its guild page (2026-11-07).
-- The last roster read while playing is kept (this session only, in memory)
-- with its own snapshotAt, and used whenever the live read fails. Leaving the
-- guild (PLAYER_GUILD_UPDATE while not in one) drops it. The cache holds the
-- motd / infoText read with that roster; one it could not read stays absent.
Guild.cache = nil
--- Background refreshes on GUILD_ROSTER_UPDATE run at most this often.
Guild.REFRESH_SECONDS = 10
local refreshedAt

--- Read the roster quietly and keep it, when the client has one. `force`
--- skips the REFRESH_SECONDS throttle.
function Guild.Refresh(force)
    local now = ns.SafeCall(GetServerTime) or time()
    if not force and refreshedAt and now - refreshedAt < Guild.REFRESH_SECONDS then return false end
    local data = buildLive(true)
    if not data then return false end
    Guild.cache, refreshedAt = data, now
    return true
end

-- The client names a different guild than the cached roster's: the player
-- changed guilds, so the cached roster is someone else's.
local function dropOtherGuild()
    local live = liveName()
    if Guild.cache and live and live ~= Guild.cache.name then Guild.cache, refreshedAt = nil, nil end
end

--- The player's guild name: live, else the cached roster's (logout).
function Guild.Name()
    return liveName() or (Guild.cache and Guild.cache.name) or nil
end

-- The cached roster as the current /rl guildnotes setting allows: a roster
-- read with notes on loses them once notes are turned off.
local function cachedForExport()
    local cache = Guild.cache
    if type(LedgerLinkDB) == "table" and LedgerLinkDB.guildNotes == true then return cache end
    local members = Json.array()
    for i, m in ipairs(cache.members) do
        local row = {}
        for k, v in pairs(m) do if k ~= "note" then row[k] = v end end
        members[i] = row
    end
    return { name = cache.name, rawRealm = cache.rawRealm, snapshotAt = cache.snapshotAt,
        canViewOfficerNote = false, members = members, motd = cache.motd, infoText = cache.infoText }
end

--- The live roster (also refreshing the cache), else the cached one.
function Guild.Build()
    local data, err = buildLive(false)
    if data then
        Guild.cache, refreshedAt = data, ns.SafeCall(GetServerTime) or time()
        return data
    end
    dropOtherGuild()
    if Guild.cache then return cachedForExport() end
    return nil, err
end

--- Split `data.members` into pages of MEMBERS_PER_PAGE. Every page repeats
--- name / rawRealm / snapshotAt / canViewOfficerNote (the server checks them);
--- motd / infoText go on page 1 only, where the server reads them.
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
    chunks[1].motd, chunks[1].infoText = data.motd, data.infoText
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

-- Re-read the roster, or drop the cache when the player is not in a guild
-- (left or removed from it).
local function reconcile()
    if inGuildNow() then
        dropOtherGuild() -- the new guild's roster may not have loaded yet
        Guild.Refresh(true)
    else
        Guild.cache, refreshedAt = nil, nil
        textLoadedFor, textLoadedBy = nil, nil
    end
end

function Guild.OnEvent(event, unit)
    if event == "GUILD_ROSTER_UPDATE" then
        if not leavingWorld then
            if rosterCount() > 0 then
                markTextLoaded("GUILD_ROSTER_UPDATE")
            else
                textLoadedFor, textLoadedBy = nil, nil -- the client dropped the guild data
            end
            Guild.Refresh(false)
        end
        if pending then
            local done = pending
            pending = nil
            done()
        end
    elseif event == "GUILD_MOTD" then
        -- The server sent the Message of the Day ("" = an officer cleared it).
        if leavingWorld then return end
        markTextLoaded("GUILD_MOTD")
        Guild.Refresh(true)
    elseif event == "PLAYER_GUILD_UPDATE" then
        if leavingWorld or (unit ~= nil and unit ~= "player") then return end
        reconcile()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Also catches a guild left during the loading screen, whose
        -- PLAYER_GUILD_UPDATE was ignored above.
        leavingWorld = false
        reconcile()
    elseif event == "PLAYER_LEAVING_WORLD" then
        leavingWorld = true -- first: this read must not trust a "" text (readBoxes)
        Guild.Refresh(true) -- the last chance to read it before logout
    end
end

local events = CreateFrame("Frame")
Guild.frame = events
events:RegisterEvent("GUILD_ROSTER_UPDATE")
for _, event in ipairs({ "GUILD_MOTD", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, unit) Guild.OnEvent(event, unit) end)

ns.Export.RegisterSection("guild", Guild.Build, { paginate = Guild.Paginate, prepare = Guild.Prepare })
