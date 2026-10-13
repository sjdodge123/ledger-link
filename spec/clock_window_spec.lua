-- ROK-1756 (Raid Ledger #1568): every exportedAt, plus guild data.snapshotAt,
-- must be within +1 day / -365 days of the SERVER clock; raid pulls only get
-- the +1 day bound. The test-side mirror takes the clock as `now` (seconds),
-- like Raid Ledger's pinned exportClock.
local loadAddon = require("spec.support.load_addon")
local importString = require("spec.support.import")

local DAY = 86400

local function export(section, setup)
    local ns = loadAddon()
    if setup then setup(ns) end
    return table.concat(assert(ns.Export.RunPages(section)), "\n")
end

local function code(paste, now)
    local ok, err = pcall(importString, paste, { now = now })
    if ok then return "ok" end
    return err.code
end

describe("export clock window (mirror)", function()
    local T = 1790000000 -- the stub's GetServerTime

    it("accepts an export stamped within a day ahead and a year behind", function()
        local paste = export("char")
        assert.equal("ok", code(paste, T))
        assert.equal("ok", code(paste, T - DAY + 1)) -- export just under a day in the future
        assert.equal("ok", code(paste, T + 365 * DAY)) -- exactly a year old
    end)

    it("rejects an export more than a day in the future or more than a year old", function()
        local paste = export("char")
        assert.equal("INVALID_PAYLOAD", code(paste, T - DAY - 1))
        assert.equal("INVALID_PAYLOAD", code(paste, T + 365 * DAY + 1))
    end)

    it("bounds the guild snapshot like exportedAt", function()
        assert.equal("INVALID_PAYLOAD", code(export("guild"), T + 365 * DAY + 1))
    end)

    it("gives raid pulls only the future bound", function()
        local function pulls(ns, startAt)
            WowStub.raid(5)
            WowStub.state.serverTime = startAt
            ns.Raid.OnEvent("ENCOUNTER_START", 663, "Lucifron", 9, 40)
            ns.Raid.OnEvent("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
            WowStub.state.serverTime = T
        end
        assert.equal("ok", code(export("raid", function(ns) pulls(ns, T - 400 * DAY) end), T))
        assert.equal("INVALID_PAYLOAD", code(export("raid", function(ns) pulls(ns, T + 2 * DAY) end), T))
    end)

    it("skips the check when no clock is given (callers that don't pin one)", function()
        assert.equal("ok", code(export("char"), nil))
    end)
end)
