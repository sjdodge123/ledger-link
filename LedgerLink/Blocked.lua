-- Records "LedgerLink has been blocked from an action only available to the
-- Blizzard UI" (seen on the beta, 2026-10-05). The game names the blocked
-- function in ADDON_ACTION_FORBIDDEN / ADDON_ACTION_BLOCKED; we keep it with the
-- command that preceded it so a tester can report it via /rl probe.
local addonName, ns = ...

local Blocked = {}
ns.Blocked = Blocked

Blocked.MAX = 10
--- Blocks seen this session (recorded or not): a caller compares it before and
--- after a risky call, since the block events fire during the call itself.
Blocked.count = 0
-- Each blocked function is announced in chat once per session; every block is
-- still recorded. A background read blocked on every refresh spammed chat
-- (2026-11-11).
local announced = {}

function Blocked.OnEvent(event, blockedAddon, fn)
    if blockedAddon ~= addonName then return end
    Blocked.count = Blocked.count + 1
    LedgerLinkDB.blocked = LedgerLinkDB.blocked or {}
    local list = LedgerLinkDB.blocked
    list[#list + 1] = {
        event = event, fn = tostring(fn), at = time(), after = ns.lastCommand or "(no command yet)",
    }
    while #list > Blocked.MAX do table.remove(list, 1) end
    if announced[tostring(fn)] then return end
    announced[tostring(fn)] = true
    ns.Print(string.format("The game blocked %s (after %s). Please send /rl probe to the addon developer.",
        tostring(fn), list[#list].after))
end

-- Restriction types in a fixed order (Enum.AddOnRestrictionType on 12.0-era
-- clients: Combat, Encounter, ChallengeMode, PvPMatch, Map, Chat).
local function restrictionTypes()
    local types = type(Enum) == "table" and Enum.AddOnRestrictionType
    local out = {}
    if type(types) ~= "table" then return out end
    for name, value in pairs(types) do
        if type(value) == "number" then out[#out + 1] = { name = name, value = value } end
    end
    table.sort(out, function(a, b) return a.value < b.value end)
    return out
end

--- The names of the addon restrictions the game is enforcing right now
--- ("combat lockdown" for InCombatLockdown()), empty when none. APIs marked
--- HasRestrictions (C_GuildInfo.GetMOTD / GetInfoText) are blocked while one is.
function Blocked.ActiveRestrictions()
    local active = {}
    local okCombat, inCombat = pcall(function() return InCombatLockdown() end)
    if okCombat and inCombat == true then active[#active + 1] = "combat lockdown" end
    local api = type(C_RestrictedActions) == "table" and C_RestrictedActions.IsAddOnRestrictionActive
    if type(api) ~= "function" then return active end
    for _, t in ipairs(restrictionTypes()) do
        local ok, on = pcall(api, t.value)
        if ok and on == true then active[#active + 1] = t.name end
    end
    return active
end

--- Probe line: which restrictions are on, or whether the client can't say.
function Blocked.RestrictionLine()
    local api = type(C_RestrictedActions) == "table" and C_RestrictedActions.IsAddOnRestrictionActive
    local active = Blocked.ActiveRestrictions()
    local text = #active > 0 and table.concat(active, ", ") or "none"
    if type(api) ~= "function" then text = text .. " (C_RestrictedActions.IsAddOnRestrictionActive missing)" end
    return "addon restrictions: " .. text
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
