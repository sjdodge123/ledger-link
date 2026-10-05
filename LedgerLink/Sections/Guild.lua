-- Guild roster export (`!RL1!guild[-<n>of<m>]!...`).
-- TODO(ROK-1723 lane 2): C_GuildInfo.GuildRoster() -> GUILD_ROSTER_UPDATE ->
-- GetGuildRosterInfo(i); paging; never emit officerNote.
local _, ns = ...

ns.Export.RegisterSection("guild", function()
    return nil, "Guild export is not yet supported in this version."
end)
