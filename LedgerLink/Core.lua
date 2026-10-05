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
end

local HELP = {
    "/rl export char - export this character (gear, talents, lockouts)",
    "/rl export guild - export the guild roster (big guilds come in pages)",
    "/rl export raid - export recorded boss pulls (last 50)",
    "/rl raid clear - forget recorded boss pulls",
    "/rl guildnotes on|off - include public notes in the guild export (default off)",
    "/rl ruleset normal|pvp|rp|hardcore - set this character's ruleset",
    "/rl region us|eu|kr|tw|cn - your region, only needed where the client doesn't report one (beta)",
    "/rl status - show the last export times",
    "/rl probe - beta checks in one copyable report (paste it to the addon developer)",
    "Paste the string into Raid Ledger: your character -> Import string.",
}

local function showHelp()
    ns.Print("v" .. ns.VERSION .. " - commands (/rl or /ledgerlink):")
    for _, line in ipairs(HELP) do print("  " .. line) end
end

local function setRuleset(arg)
    local ruleset = RULESET_ALIASES[arg or ""]
    if not ruleset then
        ns.Print("Usage: /rl ruleset normal|pvp|rp|hardcore")
        return
    end
    LedgerLinkCharDB.ruleset = ruleset
    ns.Print("Ruleset set to " .. ruleset .. ".")
end

local function setRegion(arg)
    if not ns.Identity.REGIONS[arg or ""] then
        ns.Print("Usage: /rl region us|eu|kr|tw|cn")
        return
    end
    LedgerLinkDB.region = arg
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
    if LedgerLinkDB.region then ns.Print("Region: " .. LedgerLinkDB.region .. " (used if the game doesn't report one)") end
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

local function runExport(section)
    if inCombat() then return end
    ns.Export.Prepare(section, function() showExport(section) end)
end

local function setGuildNotes(arg)
    if arg ~= "on" and arg ~= "off" then
        ns.Print("Usage: /rl guildnotes on|off (public notes only; officer notes are never exported)")
        return
    end
    LedgerLinkDB.guildNotes = arg == "on"
    ns.Print("Public guild notes will " .. (arg == "on" and "" or "not ") .. "be included in /rl export guild.")
end

local function raidCommand(arg)
    if arg == "clear" then
        ns.Raid.Clear()
        ns.Print("Recorded boss pulls cleared.")
    else
        ns.Print(string.format("%d boss pull(s) recorded. /rl export raid to export, /rl raid clear to forget them.",
            #ns.Raid.Pulls()))
    end
end

function ns.HandleSlash(msg)
    ns.lastCommand = "/rl " .. tostring(msg or "")
    local cmd, rest = string.match(string.lower(msg or ""), "^%s*(%S*)%s*(.-)%s*$")
    if cmd == "export" then
        runExport(rest ~= "" and rest or "char")
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
