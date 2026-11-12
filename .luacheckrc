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
    "UnitLevel", "UnitFactionGroup", "GetGuildInfo", "IsInGuild", "InCombatLockdown",
    -- char section
    "GetInventoryItemLink", "GetInventoryItemID", "C_Item", "C_ClassTalents", "C_Traits",
    -- char section, Phase 2 (ROK-1742): talent names, gender, quests
    "C_Spell", "GetSpellInfo", "UnitSex", "C_QuestLog",
    "GetNumSavedInstances", "GetSavedInstanceInfo",
    -- guild section
    "GetNumGuildMembers", "GetGuildRosterInfo", "GetGuildRosterLastOnline", "C_GuildInfo", "issecretvalue",
    -- addon restrictions (12.0-era clients; may be missing)
    "C_RestrictedActions",
    -- char section, Mailworthy guild contributions (ROK-2148; the Mailworthy addon's API)
    "MailworthyAPI",
    -- raid section
    "GetNumGroupMembers", "IsInRaid", "GetInstanceInfo",
    -- loot recorder (contract v2 draft, not exported yet; each may be missing)
    "IsInGroup", "IsInInstance", "C_PartyInfo", "GetLootMethod", "GetLootThreshold", "GetItemInfo", "C_LootHistory",
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
        "CreateFrame", "Enum", "C_EncodingUtil", "C_Item", "C_ClassTalents", "C_Traits",
        "MailworthyAPI" },
    allow_defined_top = true,
}
files["tools/**"] = { globals = { "WowStub" } }
