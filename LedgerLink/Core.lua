-- LedgerLink: namespace, saved variables and slash commands.
local addonName, ns = ...

ns.NAME = addonName
ns.VERSION = "0.1.0" -- keep in sync with ## Version in LedgerLink.toc

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
end

local HELP = {
    "/rl export char - export this character (gear, talents, lockouts)",
    "/rl export guild - export the guild roster (not yet supported)",
    "/rl export raid - export recorded boss pulls (not yet supported)",
    "/rl ruleset normal|pvp|rp|hardcore - set this character's ruleset",
    "/rl status - show the last export times",
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

local function showStatus()
    local any = false
    for section, info in pairs(LedgerLinkDB.lastExport) do
        any = true
        ns.Print(string.format("%s: exported at %s (%d bytes)",
            section, date("%Y-%m-%d %H:%M", info.at), info.bytes))
    end
    if not any then ns.Print("No exports yet. Try /rl export char") end
    ns.Print("Ruleset: " .. (LedgerLinkCharDB.ruleset or "not set (/rl ruleset)"))
end

local function runExport(section)
    if InCombatLockdown() then
        ns.Print("Can't export in combat - try again after combat.")
        return
    end
    local str, err = ns.Export.Run(section)
    if not str then
        ns.Print(err)
        return
    end
    LedgerLinkDB.lastExport[section] = { at = time(), bytes = #str }
    ns.ExportFrame.Show(section, str)
end

function ns.HandleSlash(msg)
    local cmd, rest = string.match(string.lower(msg or ""), "^%s*(%S*)%s*(.-)%s*$")
    if cmd == "export" then
        runExport(rest ~= "" and rest or "char")
    elseif cmd == "ruleset" then
        setRuleset(rest)
    elseif cmd == "status" then
        showStatus()
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
