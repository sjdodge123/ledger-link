-- "LedgerLink has been blocked from an action only available to the Blizzard
-- UI" (beta, 2026-10-05): the game names the blocked function in
-- ADDON_ACTION_FORBIDDEN / ADDON_ACTION_BLOCKED. The addon records it with the
-- command that preceded it, says so in chat, and /rl probe reports it.
local loadAddon = require("spec.support.load_addon")

local function printed(text)
    for _, line in ipairs(WowStub.printed) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

describe("blocked actions", function()
    it("listens for both block events", function()
        local ns = loadAddon()
        assert.is_true(ns.Blocked.frame.events.ADDON_ACTION_FORBIDDEN)
        assert.is_true(ns.Blocked.frame.events.ADDON_ACTION_BLOCKED)
    end)

    it("records the blocked function with the command before it, and says so in chat", function()
        local ns = loadAddon()
        ns.HandleSlash("export guild")
        ns.Blocked.OnEvent("ADDON_ACTION_FORBIDDEN", "LedgerLink", "GuildRoster()")
        local entry = LedgerLinkDB.blocked[1]
        assert.equal("ADDON_ACTION_FORBIDDEN", entry.event)
        assert.equal("GuildRoster()", entry.fn)
        assert.equal("/rl export guild", entry.after)
        assert.is_number(entry.at)
        assert.is_true(printed("GuildRoster()"))
        assert.is_true(printed("/rl probe"))
    end)

    it("ignores other addons' blocks", function()
        local ns = loadAddon()
        ns.Blocked.OnEvent("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "CastSpellByName()")
        assert.equal(0, #LedgerLinkDB.blocked)
    end)

    it("keeps the newest 10", function()
        local ns = loadAddon()
        for i = 1, 12 do ns.Blocked.OnEvent("ADDON_ACTION_BLOCKED", "LedgerLink", "Fn" .. i .. "()") end
        assert.equal(10, #LedgerLinkDB.blocked)
        assert.equal("Fn3()", LedgerLinkDB.blocked[1].fn)
        assert.equal("Fn12()", LedgerLinkDB.blocked[10].fn)
    end)

    it("shows up in /rl probe", function()
        local ns = loadAddon()
        ns.HandleSlash("status")
        ns.Blocked.OnEvent("ADDON_ACTION_FORBIDDEN", "LedgerLink", "SomethingProtected()")
        local text = ns.Probe.Report()
        assert.truthy(text:find("blocked: ADDON_ACTION_FORBIDDEN SomethingProtected() after /rl status", 1, true), text)
    end)
end)
