-- "Export all" (Raid Ledger ROK-1737, CONTRACT.md §5.1): char + guild (every
-- page) + raid in one copy box, one string per line, pasted into Raid Ledger
-- at once. Every string keeps its single-section wire format.
local loadAddon = require("spec.support.load_addon")
local importString = require("spec.support.import")

local function pull(ns, id)
    ns.Raid.OnEvent("ENCOUNTER_START", id, "Boss " .. id, 9, 40)
    WowStub.state.serverTime = WowStub.state.serverTime + 120
    ns.Raid.OnEvent("ENCOUNTER_END", id, "Boss " .. id, 9, 40, 1)
end

local function printed(text)
    for _, line in ipairs(WowStub.printed) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

local function sections(paste)
    local out = {}
    for _, g in ipairs(importString(paste).groups) do out[#out + 1] = g.section .. ":" .. g.pages end
    return table.concat(out, " ")
end

describe("/rl export all", function()
    local ns
    before_each(function()
        ns = loadAddon()
        WowStub.raid(5)
        pull(ns, 663)
    end)

    it("puts char, guild and raid in one box, one string per line, as one valid paste", function()
        ns.HandleSlash("export all")
        local text = ns.ExportFrame.GetText()
        local lines = {}
        for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
        assert.equal(3, #lines)
        assert.truthy(lines[1]:match("^!RL1!char!"))
        assert.truthy(lines[2]:match("^!RL1!guild!"))
        assert.truthy(lines[3]:match("^!RL1!raid!"))
        assert.equal("char:1 guild:1 raid:1", sections(text))
        assert.truthy(LedgerLinkDB.lastExport.all)
        assert.truthy(ns.ExportFrame.GetFooter():find("all at once", 1, true))
    end)

    it("includes every page of a big guild (still within the 10-string cap)", function()
        WowStub.state.guildRoster = WowStub.roster(600)
        ns.HandleSlash("export all")
        assert.equal("char:1 guild:3 raid:1", sections(ns.ExportFrame.GetText()))
    end)

    it("leaves out the guild when not in one, and says so", function()
        WowStub.state.guild = nil
        ns.HandleSlash("export all")
        assert.equal("char:1 raid:1", sections(ns.ExportFrame.GetText()))
        assert.is_true(printed("not in a guild"))
    end)

    it("leaves out the raid when no pulls are recorded, and says so", function()
        ns.ClearPulls()
        ns.HandleSlash("export all")
        assert.equal("char:1 guild:1", sections(ns.ExportFrame.GetText()))
        assert.is_true(printed("no boss pulls"))
    end)

    it("waits for the guild roster when it isn't loaded yet", function()
        local rows = WowStub.state.guildRoster
        WowStub.state.guildRoster = {}
        ns.HandleSlash("export all")
        assert.is_nil(LedgerLinkDB.lastExport.all)
        WowStub.state.guildRoster = rows
        ns.Guild.OnEvent("GUILD_ROSTER_UPDATE")
        assert.equal("char:1 guild:1 raid:1", sections(ns.ExportFrame.GetText()))
    end)

    it("refuses a paste over Raid Ledger's 256 KB limit and suggests separate exports", function()
        local limit, largest = ns.Export.MAX_PASTE_BYTES, 0
        for _, section in ipairs({ "char", "guild", "raid" }) do
            largest = math.max(largest, #ns.Export.RunPages(section)[1])
        end
        -- Each section fits on its own; the three together don't.
        ns.Export.MAX_PASTE_BYTES = largest + 1
        ns.HandleSlash("export all")
        ns.Export.MAX_PASTE_BYTES = limit
        assert.is_nil(LedgerLinkDB.lastExport.all)
        assert.is_true(printed("/rl export guild"))
    end)

    it("is the panel's export button, and never moves keyboard focus", function()
        WowStub.focusCalls = 0
        ns.Panel.Show()
        local b = assert(WowStub.frames.LedgerLinkPanelExport)
        b.scripts.OnClick(b, "LeftButton")
        assert.equal("char:1 guild:1 raid:1", sections(ns.ExportFrame.GetText()))
        assert.equal(0, WowStub.focusCalls)
    end)
end)
