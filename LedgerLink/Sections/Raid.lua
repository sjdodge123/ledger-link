-- Boss-pull export (`!RL1!raid!...`).
-- TODO(ROK-1723 lane 2): ENCOUNTER_START/ENCOUNTER_END ring buffer in
-- LedgerLinkDB + roster GUIDs at pull time.
local _, ns = ...

ns.Export.RegisterSection("raid", function()
    return nil, "Raid export is not yet supported in this version."
end)
