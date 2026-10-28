-- Companion outbox (Raid Ledger ROK-1964): the latest export of each character,
-- kept in SavedVariables so the Raid Ledger Companion can upload it once the
-- client writes LedgerLink.lua (logout, /reload, clean exit). Paste stays the
-- default; this only keeps a copy.
--
--   LedgerLinkDB.outbox[<who.guid>] = {
--       exportedAt = <unix s, from the run's payload>,
--       section    = "char" | "guild" | "raid" | "all",
--       text       = <the v1 export strings, one per line>,
--       at         = <unix s when stored>,
--       source     = "export" (Export click / slash) | "logout" (auto-export),
--   }
--
-- `text` is exactly what the copy window shows (a paged export: every page,
-- joined by newlines, as Export.Run builds it). The wire format is unchanged.
local _, ns = ...

local Outbox = {}
ns.Outbox = Outbox

--- Characters kept (latest run per character); the oldest `at` is dropped.
Outbox.MAX_ENTRIES = 10

-- Characters that exported by click this session (see Outbox.OnLogout).
local clickedThisSession = {}

local function box()
    if type(LedgerLinkDB) ~= "table" then return nil end
    if type(LedgerLinkDB.outbox) ~= "table" then LedgerLinkDB.outbox = {} end
    return LedgerLinkDB.outbox
end

local function entryAt(entry)
    return type(entry) == "table" and tonumber(entry.at) or 0
end

--- Drop the oldest entries (never `keep`) until at most MAX_ENTRIES remain.
local function trim(entries, keep)
    while true do
        local count, oldestKey, oldestAt = 0, nil, nil
        for guid, entry in pairs(entries) do
            count = count + 1
            if guid ~= keep and (oldestAt == nil or entryAt(entry) < oldestAt) then
                oldestKey, oldestAt = guid, entryAt(entry)
            end
        end
        if count <= Outbox.MAX_ENTRIES or oldestKey == nil then return end
        entries[oldestKey] = nil
    end
end

--- Store `text` (the export just built) as this character's latest run.
--- The exporter + exportedAt come from the payload Export.BuildPayload built.
function Outbox.Store(section, text, source)
    local built, entries = ns.Export.lastBuilt, box()
    if not entries or type(built) ~= "table" or type(built.guid) ~= "string" then return false end
    if type(text) ~= "string" or text == "" or #text > ns.Export.MAX_PASTE_BYTES then return false end
    entries[built.guid] = {
        exportedAt = built.exportedAt,
        section = section,
        text = text,
        at = time(),
        source = source or "export",
    }
    if (source or "export") == "export" then clickedThisSession[built.guid] = true end
    trim(entries, built.guid)
    return true
end

--- Auto-export on logout is on unless the player turned it off.
function Outbox.AutoEnabled()
    return not (type(LedgerLinkDB) == "table" and LedgerLinkDB.autoExport == false)
end

local function exportForLogout()
    local tokens = ns.Export.RunAll()
    if tokens then return Outbox.Store("all", table.concat(tokens, "\n"), "logout") end
    -- RunAll fails as a whole (e.g. the guild roster never loaded): fall back to
    -- the character alone, but never replace a run the player clicked this
    -- session - it holds a guild section this one would lose.
    local pages = ns.Export.RunPages("char")
    if not pages then return false end
    local built = ns.Export.lastBuilt
    if type(built) == "table" and clickedThisSession[built.guid] then return false end
    return Outbox.Store("char", table.concat(pages, "\n"), "logout")
end

--- PLAYER_LOGOUT: build the Export-all strings and store them. Never throws:
--- a failure keeps the previous outbox entry and must not disturb logout.
function Outbox.OnLogout()
    if not Outbox.AutoEnabled() then return false end
    local ok, stored = pcall(exportForLogout)
    return ok and stored == true
end

Outbox.frame = CreateFrame("Frame")
Outbox.frame:RegisterEvent("PLAYER_LOGOUT")
Outbox.frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then Outbox.OnLogout() end
end)
