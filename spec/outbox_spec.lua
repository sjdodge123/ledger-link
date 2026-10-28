-- Companion outbox (Raid Ledger ROK-1964): every export keeps its exact copy-window
-- text in LedgerLinkDB.outbox[guid] (latest per character, bounded), and
-- PLAYER_LOGOUT stores an Export all without a click. Wire format unchanged.
local loadAddon = require("spec.support.load_addon")
local importString = require("spec.support.import")

local GUID = "Player-4395-0ABCDEF0"

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function logout(ns)
    local handler = ns.Outbox.frame:GetScript("OnEvent")
    assert.is_true(ns.Outbox.frame.events.PLAYER_LOGOUT)
    handler(ns.Outbox.frame, "PLAYER_LOGOUT")
end

describe("Companion outbox", function()
    local ns
    before_each(function() ns = loadAddon() end)

    it("stores exactly the copy-window text of /rl export char, keyed by the exporter's guid", function()
        ns.HandleSlash("export char")
        local entry = LedgerLinkDB.outbox[GUID]
        assert.is_table(entry)
        assert.equal(ns.ExportFrame.GetText(), entry.text)
        assert.equal("char", entry.section)
        assert.equal("export", entry.source)
        local group = importString(entry.text).groups[1]
        assert.equal("char", group.section)
        assert.equal(group.payloads[1].exportedAt, entry.exportedAt)
    end)

    it("stores exactly the copy-window text of Export all", function()
        ns.HandleSlash("export all")
        local entry = LedgerLinkDB.outbox[GUID]
        assert.equal(ns.ExportFrame.GetText(), entry.text)
        assert.equal("all", entry.section)
    end)

    it("stores every page of a paged guild export, joined by newlines (Export.Run)", function()
        WowStub.state.guildRoster = WowStub.roster(600)
        ns.HandleSlash("export guild")
        local entry = LedgerLinkDB.outbox[GUID]
        assert.equal(ns.Export.Run("guild"), entry.text)
        assert.equal("guild", entry.section)
        assert.equal(3, importString(entry.text).groups[1].pages)
    end)

    it("keeps only the latest run per character", function()
        ns.HandleSlash("export char")
        ns.HandleSlash("export all")
        assert.equal(1, count(LedgerLinkDB.outbox))
        assert.equal("all", LedgerLinkDB.outbox[GUID].section)
    end)

    it("keeps at most MAX_ENTRIES characters, dropping the oldest", function()
        LedgerLinkDB.outbox = {}
        for i = 1, ns.Outbox.MAX_ENTRIES do
            LedgerLinkDB.outbox[string.format("Player-1-%08X", i)] = { at = 1000 + i, text = "x" }
        end
        ns.HandleSlash("export char")
        assert.equal(ns.Outbox.MAX_ENTRIES, count(LedgerLinkDB.outbox))
        assert.is_nil(LedgerLinkDB.outbox["Player-1-00000001"])
        assert.is_table(LedgerLinkDB.outbox["Player-1-00000002"])
        assert.is_table(LedgerLinkDB.outbox[GUID])
    end)

    it("refuses text over the paste limit", function()
        ns.Export.RunPages("char")
        assert.is_false(ns.Outbox.Store("char", string.rep("A", ns.Export.MAX_PASTE_BYTES + 1)))
        assert.is_nil(LedgerLinkDB.outbox[GUID])
    end)

    it("survives a reload: Init keeps an outbox loaded from SavedVariables", function()
        LedgerLinkDB = { outbox = { [GUID] = { text = "kept", at = 1 } } }
        ns.Init()
        assert.equal("kept", LedgerLinkDB.outbox[GUID].text)
    end)

    describe("auto-export on PLAYER_LOGOUT", function()
        it("stores an Export all without a click", function()
            logout(ns)
            local entry = LedgerLinkDB.outbox[GUID]
            assert.equal("all", entry.section)
            assert.equal("logout", entry.source)
            assert.equal(ns.Export.Run("char"), entry.text:match("^[^\n]+"))
        end)

        it("does nothing when turned off", function()
            ns.HandleSlash("autoexport off")
            assert.is_false(LedgerLinkDB.autoExport)
            logout(ns)
            assert.is_nil(LedgerLinkDB.outbox[GUID])
        end)

        it("falls back to the character when the guild roster never loaded", function()
            WowStub.state.guildRoster = {}
            logout(ns)
            assert.equal("char", LedgerLinkDB.outbox[GUID].section)
        end)

        it("never replaces this session's clicked Export all with a char-only fallback", function()
            ns.HandleSlash("export all")
            WowStub.state.guildRoster = {}
            logout(ns)
            assert.equal("all", LedgerLinkDB.outbox[GUID].section)
            assert.equal("export", LedgerLinkDB.outbox[GUID].source)
        end)

        it("swallows errors and leaves the saved data intact", function()
            ns.HandleSlash("export char")
            local before = LedgerLinkDB.outbox[GUID].text
            ns.Export.RunAll = function() error("boom") end
            assert.has_no.errors(function() logout(ns) end)
            assert.equal(before, LedgerLinkDB.outbox[GUID].text)
            assert.is_table(LedgerLinkDB.lastExport)
        end)
    end)
end)
