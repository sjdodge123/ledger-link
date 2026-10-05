-- Records "LedgerLink has been blocked from an action only available to the
-- Blizzard UI" (seen on the beta, 2026-10-05). The game names the blocked
-- function in ADDON_ACTION_FORBIDDEN / ADDON_ACTION_BLOCKED; we keep it with the
-- command that preceded it so a tester can report it via /rl probe.
local addonName, ns = ...

local Blocked = {}
ns.Blocked = Blocked

Blocked.MAX = 10

function Blocked.OnEvent(event, blockedAddon, fn)
    if blockedAddon ~= addonName then return end
    LedgerLinkDB.blocked = LedgerLinkDB.blocked or {}
    local list = LedgerLinkDB.blocked
    list[#list + 1] = {
        event = event, fn = tostring(fn), at = time(), after = ns.lastCommand or "(no command yet)",
    }
    while #list > Blocked.MAX do table.remove(list, 1) end
    ns.Print(string.format("The game blocked %s (after %s). Please send /rl probe to the addon developer.",
        tostring(fn), list[#list].after))
end

--- Probe lines for the recorded blocks, oldest first.
function Blocked.Lines()
    local lines = {}
    for _, b in ipairs(LedgerLinkDB and LedgerLinkDB.blocked or {}) do
        lines[#lines + 1] = string.format("blocked: %s %s after %s at %s",
            b.event, b.fn, b.after, date("%Y-%m-%d %H:%M:%S", b.at))
    end
    return lines
end

local frame = CreateFrame("Frame")
Blocked.frame = frame
for _, event in ipairs({ "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED" }) do
    pcall(frame.RegisterEvent, frame, event)
end
frame:SetScript("OnEvent", function(_, event, blockedAddon, fn)
    if LedgerLinkDB then Blocked.OnEvent(event, blockedAddon, fn) end
end)
