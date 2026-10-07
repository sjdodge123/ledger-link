-- LedgerLink: namespace, saved variables and slash commands.
local addonName, ns = ...

ns.NAME = addonName
ns.VERSION = "@project-version@" -- the packager substitutes the release tag (also ## Version in the .toc)

local RULESET_ALIASES = {
    normal = "normal", pvp = "pvp", hardcore = "hardcore", hc = "hardcore",
    roleplaying = "roleplaying", rp = "roleplaying",
}

function ns.Print(msg)
    print("|cff33ff99Ledger Link|r: " .. tostring(msg))
end

function ns.Init()
    LedgerLinkDB = type(LedgerLinkDB) == "table" and LedgerLinkDB or {}
    LedgerLinkCharDB = type(LedgerLinkCharDB) == "table" and LedgerLinkCharDB or {}
    LedgerLinkDB.lastExport = LedgerLinkDB.lastExport or {}
    LedgerLinkDB.blocked = LedgerLinkDB.blocked or {}
    if ns.Minimap then ns.Minimap.Init() end
end

--- Settings changed from a slash command or the panel: keep the panel in step.
local function changed()
    if ns.Panel then ns.Panel.Refresh() end
end

local HELP = {
    "/rl - open the Ledger Link panel (or click the minimap button)",
    "/rl export char - export this character (gear, talents, lockouts)",
    "/rl export guild - export the guild roster (big guilds come in pages)",
    "/rl export raid - export recorded boss pulls (last 50)",
    "/rl export all - character, guild and raid in one box: paste them into Raid Ledger together",
    "/rl raid clear - forget recorded boss pulls",
    "/rl guildnotes on|off - include public notes in the guild export (default off)",
    "/rl ruleset normal|pvp|rp|hardcore - set this character's ruleset",
    "/rl region us|eu|kr|tw|cn - override the region where the game doesn't report one (beta; otherwise guessed from your game language)",
    "/rl status - show the last export times",
    "/rl probe - beta checks in one copyable report (paste it to the addon developer)",
    "/rl minimap on|off - show or hide the minimap button",
    "Paste the string into Raid Ledger: your character -> Import string.",
}

local function showHelp()
    ns.Print("v" .. ns.VERSION .. " - commands (/rl or /ledgerlink):")
    for _, line in ipairs(HELP) do print("  " .. line) end
end

--- Set this character's ruleset ("normal", "pvp", "rp"/"roleplaying", "hardcore"/"hc").
function ns.SetRuleset(value)
    local ruleset = RULESET_ALIASES[value or ""]
    if not ruleset then return false end
    LedgerLinkCharDB.ruleset = ruleset
    changed()
    return true, ruleset
end

local function setRuleset(arg)
    local ok, ruleset = ns.SetRuleset(arg)
    if not ok then
        ns.Print("Usage: /rl ruleset normal|pvp|rp|hardcore")
        return
    end
    ns.Print("Ruleset set to " .. ruleset .. ".")
end

--- Region used only when the game doesn't report one (the beta).
function ns.SetRegion(name)
    if not ns.Identity.REGIONS[name or ""] then return false end
    LedgerLinkDB.region = name
    if name == "cn" then
        -- The wire format allows 5 (it mirrors GetCurrentRegion), but Raid Ledger
        -- characters are us/eu/kr/tw only: a cn import fails with REGION_MISMATCH.
        ns.Print("Note: Raid Ledger can't import China-region characters, so exports with region cn won't import.")
    end
    changed()
    return true
end

local function setRegion(arg)
    if not ns.SetRegion(arg) then
        ns.Print("Usage: /rl region us|eu|kr|tw|cn")
        return
    end
    ns.Print("Region set to " .. arg .. ". It is only used when the game doesn't report one (the beta).")
end

local function showStatus()
    local any = false
    for section, info in pairs(LedgerLinkDB.lastExport) do
        any = true
        ns.Print(string.format("%s: exported at %s (%d bytes)",
            section, date("%Y-%m-%d %H:%M", info.at), info.bytes))
    end
    if not any then ns.Print("No exports yet. Try /rl export char") end
    ns.Print(string.format("Recorded boss pulls: %d (max %d)", #ns.Raid.Pulls(), ns.Raid.MAX_PULLS))
    ns.Print("Ruleset: " .. (LedgerLinkCharDB.ruleset or "not set (/rl ruleset)"))
    local regionText = ns.Identity.RegionText()
    if regionText then ns.Print("Region: " .. regionText) end
end

local function inCombat()
    if InCombatLockdown() then
        ns.Print("Can't export in combat - try again after combat.")
        return true
    end
    return false
end

local function showExport(section)
    if inCombat() then return end
    local pages, err = ns.Export.RunPages(section)
    if not pages then
        ns.Print(err)
        return
    end
    local bytes = 0
    for _, page in ipairs(pages) do bytes = bytes + #page end
    LedgerLinkDB.lastExport[section] = { at = time(), bytes = bytes, pages = #pages }
    if #pages > 1 then
        ns.Print(string.format("The %s export has %d pages - copy each one (Next >).", section, #pages))
    end
    ns.ExportFrame.Show(section, pages)
end

local function showAll()
    if inCombat() then return end
    local tokens, notes = ns.Export.RunAll()
    if not tokens then
        ns.Print(notes)
        return
    end
    local text = table.concat(tokens, "\n")
    LedgerLinkDB.lastExport.all = { at = time(), bytes = #text, pages = #tokens }
    for _, note in ipairs(notes) do ns.Print(note) end
    ns.ExportFrame.Show("all", text, ns.ExportFrame.ALL_FOOTER)
end

--- Export `section` ("char", "guild", "raid", or "all") into the copy window.
function ns.RunExport(section)
    if inCombat() then return end
    if section == "all" then
        -- The guild roster may need loading first; Guild.Prepare is a no-op outside a guild.
        ns.Export.Prepare("guild", showAll)
        return
    end
    ns.Export.Prepare(section, function() showExport(section) end)
end

function ns.SetGuildNotes(on)
    LedgerLinkDB.guildNotes = on and true or false
    changed()
end

local function setGuildNotes(arg)
    if arg ~= "on" and arg ~= "off" then
        ns.Print("Usage: /rl guildnotes on|off (public notes only; officer notes are never exported)")
        return
    end
    ns.SetGuildNotes(arg == "on")
    ns.Print("Public guild notes will " .. (arg == "on" and "" or "not ") .. "be included in /rl export guild.")
end

function ns.ClearPulls()
    ns.Raid.Clear()
    changed()
end

local function minimapCommand(arg)
    if arg ~= "on" and arg ~= "off" then
        ns.Print("Usage: /rl minimap on|off")
        return
    end
    ns.Minimap.SetShown(arg == "on")
    ns.Print("Minimap button " .. (arg == "on" and "shown." or "hidden. /rl minimap on brings it back."))
end

local function raidCommand(arg)
    if arg == "clear" then
        ns.ClearPulls()
        ns.Print("Recorded boss pulls cleared.")
    else
        ns.Print(string.format("%d boss pull(s) recorded. /rl export raid to export, /rl raid clear to forget them.",
            #ns.Raid.Pulls()))
    end
end

function ns.HandleSlash(msg)
    ns.lastCommand = "/rl " .. tostring(msg or "")
    local cmd, rest = string.match(string.lower(msg or ""), "^%s*(%S*)%s*(.-)%s*$")
    if cmd == "" then
        ns.Panel.Toggle()
    elseif cmd == "export" then
        ns.RunExport(rest ~= "" and rest or "char")
    elseif cmd == "ruleset" then
        setRuleset(rest)
    elseif cmd == "probe" then
        ns.Probe.Show()
    elseif cmd == "region" then
        setRegion(rest)
    elseif cmd == "status" then
        showStatus()
    elseif cmd == "guildnotes" then
        setGuildNotes(rest)
    elseif cmd == "raid" then
        raidCommand(rest)
    elseif cmd == "minimap" then
        minimapCommand(rest)
    else
        showHelp()
    end
end

SLASH_LEDGERLINK1 = "/rl"
SLASH_LEDGERLINK2 = "/ledgerlink"
SlashCmdList.LEDGERLINK = function(msg) ns.HandleSlash(msg) end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == addonName then
        ns.Init()
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
