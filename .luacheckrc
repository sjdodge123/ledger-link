std = "lua51"
max_line_length = 140
exclude_files = { ".luarocks/**", ".install/**", "lua_modules/**", "node_modules/**" }

-- Globals the addon defines (SavedVariables + slash command registration).
globals = {
    "LedgerLinkDB", "LedgerLinkCharDB",
    "SLASH_LEDGERLINK1", "SLASH_LEDGERLINK2", "SlashCmdList",
}

-- WoW API the addon reads. Keep this list to what the code actually calls.
read_globals = {
    -- Lua extensions the client provides
    "date", "time",
    -- identity / client
    "GetBuildInfo", "GetCurrentRegion", "GetLocale", "GetRealmName", "GetServerTime",
    "GetUnitName", "UnitName", "UnitFullName", "UnitGUID", "UnitClass", "UnitRace",
    "UnitLevel", "UnitFactionGroup", "GetGuildInfo", "InCombatLockdown",
    -- char section
    "GetInventoryItemLink", "GetInventoryItemID", "C_Item", "C_ClassTalents", "C_Traits",
    "GetNumSavedInstances", "GetSavedInstanceInfo",
    -- guild section
    "GetNumGuildMembers", "GetGuildRosterInfo", "GetGuildRosterLastOnline", "C_GuildInfo",
    -- raid section
    "GetNumGroupMembers", "IsInRaid", "GetInstanceInfo",
    -- encoding
    "C_EncodingUtil", "Enum",
    -- /rl probe (read-only; each one may be missing on the beta)
    "GetCurrentRegionName", "GetCVar", "GetNormalizedRealmName", "C_GameRules", "C_Seasons",
    -- /rl probe, Raid Ledger S3 request (read-only, each may be missing)
    "UnitSex", "C_QuestLog", "C_Spell", "GetSpellInfo",
    -- UI
    "CreateFrame", "UIParent", "UISpecialFrames", "ChatFontNormal",
    "Minimap", "GameTooltip", "GetCursorPosition",
}

files["spec/**"] = {
    std = "+busted",
    globals = { "WowStub", "print", "unpack", "time", "date", "UISpecialFrames", "UIParent", "ChatFontNormal",
        "CreateFrame", "Enum", "C_EncodingUtil", "C_Item", "C_ClassTalents", "C_Traits" },
    allow_defined_top = true,
}
files["tools/**"] = { globals = { "WowStub" } }
