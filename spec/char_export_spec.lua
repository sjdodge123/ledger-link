local loadAddon = require("spec.support.load_addon")
local decode = require("spec.support.decode")
local dkjson = require("dkjson")

-- Key sets copied from the Raid Ledger contract (wow-addon-export.schema.ts).
-- Every object there is .strict(): an extra key rejects the whole string.
local ENVELOPE = { "addonVersion", "client", "data", "exportedAt", "schema", "section", "who" }
local CLIENT = { "build", "interface", "locale", "region" }
local WHO_ALLOWED = { "class", "faction", "fullName", "guid", "guildName", "level", "race", "raw", "ruleset" }
local WHO_REQUIRED = { "class", "faction", "fullName", "guid", "level", "race", "raw", "ruleset" }
local RAW_ALLOWED = { "getUnitName", "realmName", "unitFullName", "unitName" }
local CHAR_DATA = { "gear", "lockouts", "talents" }
local GEAR_ALLOWED = { "ilvl", "itemId", "link", "slot" }
local TALENTS_ALLOWED = { "configId", "importString", "nodes" }
local NODE_ALLOWED = { "entryId", "nodeId", "rank" }
local LOCKOUT = { "difficultyId", "instanceId", "killed", "name", "resetAt", "total" }

local function keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function assertSubset(t, allowed, label)
    local set = {}
    for _, k in ipairs(allowed) do set[k] = true end
    for k in pairs(t) do
        assert(set[k], label .. " has unexpected key '" .. tostring(k) .. "'")
    end
end

local function assertHas(t, required, label)
    for _, k in ipairs(required) do
        assert(t[k] ~= nil, label .. " is missing '" .. k .. "'")
    end
end

local function isInt(v) return type(v) == "number" and v == math.floor(v) end

describe("/rl export char", function()
    local ns

    before_each(function() ns = loadAddon() end)

    local function exportChar()
        local str, err = ns.Export.Run("char")
        assert.is_nil(err)
        return decode(str), str
    end

    it("emits a !RL1!char! header with padded standard base64", function()
        local d, str = exportChar()
        assert.equals(1, d.version)
        assert.equals("char", d.section)
        assert.truthy(str:match("^!RL1!char![A-Za-z0-9+/]+=?=?$"))
        assert.equals(0, #d.body % 4)
    end)

    it("envelope keys match the contract exactly", function()
        local p = exportChar().payload
        assert.same(ENVELOPE, keys(p))
        assert.same(CLIENT, keys(p.client))
        assert.equals(1, p.schema)
        assert.equals("char", p.section)
        assert.equals(ns.VERSION, p.addonVersion)
        assert.equals(1790000000, p.exportedAt)
        assert.same({ interface = 16001, build = "1.60.1.70009", locale = "enUS", region = 1 }, p.client)
    end)

    it("who block is strict, with guildName and raw tuples", function()
        local who = exportChar().payload.who
        assertSubset(who, WHO_ALLOWED, "who")
        assertHas(who, WHO_REQUIRED, "who")
        assertSubset(who.raw, RAW_ALLOWED, "who.raw")
        assert.equals("Player-4395-0ABCDEF0", who.guid)
        assert.equals("Ana Forever", who.fullName)
        assert.equals("Night Shift", who.guildName)
        assert.equals("PALADIN", who.class)
        assert.same({ "Ana", dkjson.null }, who.raw.unitName)
        assert.same({ "Ana", "Forever" }, who.raw.unitFullName)
    end)

    it("ruleset is null until set, and rp is spelled roleplaying", function()
        assert.equals(dkjson.null, exportChar().payload.who.ruleset)
        ns.HandleSlash("ruleset rp")
        assert.equals("roleplaying", exportChar().payload.who.ruleset)
        ns.HandleSlash("ruleset bogus")
        assert.equals("roleplaying", exportChar().payload.who.ruleset)
    end)

    it("region is an integer 1-5 and refuses anything else", function()
        assert.is_true(isInt(exportChar().payload.client.region))
        WowStub.state.region = 72
        local str, err = ns.Export.Run("char")
        assert.is_nil(str)
        assert.truthy(err:find("region"))
    end)

    it("char data matches the contract shape", function()
        local data = exportChar().payload.data
        assert.same(CHAR_DATA, keys(data))
        assert.equals(2, #data.gear)
        for _, item in ipairs(data.gear) do assertSubset(item, GEAR_ALLOWED, "gear item") end
        assert.same({ slot = 16, itemId = 19019, ilvl = 80, link = WowStub.state.gear[16].link }, data.gear[2])
        assertSubset(data.talents, TALENTS_ALLOWED, "talents")
        assert.equals(7, data.talents.configId)
        for _, node in ipairs(data.talents.nodes) do assertSubset(node, NODE_ALLOWED, "talent node") end
        assert.same({ { nodeId = 101, rank = 2, entryId = 9001 }, { nodeId = 103, rank = 1 } }, data.talents.nodes)
        assert.same({ LOCKOUT }, { keys(data.lockouts[1]) })
        assert.equals(1, #data.lockouts)
        assert.same({ name = "Molten Core", instanceId = 409, difficultyId = 9,
            resetAt = 1790003600, killed = 3, total = 10 }, data.lockouts[1])
    end)

    it("empty sections encode as [] and never emit extra keys", function()
        WowStub.state.gear, WowStub.state.lockouts, WowStub.state.talentConfigId = {}, {}, nil
        WowStub.state.guild = nil
        local d = exportChar()
        assert.truthy(d.json:find('"gear":[]', 1, true))
        assert.truthy(d.json:find('"lockouts":[]', 1, true))
        assert.truthy(d.json:find('"talents":{"nodes":[]}', 1, true))
        assert.is_nil(d.payload.who.guildName)
        assert.is_nil(d.json:find("officerNote", 1, true))
    end)

    it("normalises a URL-safe / unpadded EncodeBase64 to standard padded", function()
        WowStub.state.base64Variant = "urlsafe-unpadded"
        local d = exportChar()
        assert.equals(0, #d.body % 4)
        assert.equals("char", d.payload.section)
    end)

    it("rejects a malformed GUID instead of emitting it", function()
        WowStub.state.guid = "Player-4395-0abcdef"
        local str, err = ns.Export.Run("char")
        assert.is_nil(str)
        assert.truthy(err:find("GUID"))
    end)
end)

describe("slash commands", function()
    local ns

    before_each(function() ns = loadAddon() end)

    it("registers /rl and /ledgerlink", function()
        assert.equals("/rl", SLASH_LEDGERLINK1)
        assert.equals("/ledgerlink", SLASH_LEDGERLINK2)
        assert.is_function(SlashCmdList.LEDGERLINK)
    end)

    it("/rl export char shows the string in the export frame", function()
        SlashCmdList.LEDGERLINK("export char")
        local text = ns.ExportFrame.GetText()
        assert.truthy(text:match("^!RL1!char!"))
        assert.is_true(WowStub.frames.LedgerLinkExportFrame.shown)
        assert.equals(#text, LedgerLinkDB.lastExport.char.bytes)
    end)

    it("guild and raid print not yet supported", function()
        for _, section in ipairs({ "guild", "raid" }) do
            SlashCmdList.LEDGERLINK("export " .. section)
            assert.truthy(WowStub.printed[#WowStub.printed]:find("not yet supported"))
        end
    end)

    it("refuses to export in combat", function()
        WowStub.state.inCombat = true
        SlashCmdList.LEDGERLINK("export char")
        assert.truthy(WowStub.printed[#WowStub.printed]:find("combat"))
        assert.is_nil(LedgerLinkDB.lastExport.char)
    end)

    it("runs under LuaJIT (Lua 5.1 semantics, like the WoW client)", function()
        assert.equals("Lua 5.1", _VERSION)
        assert.is_table(rawget(_G, "jit"))
    end)

    it("toc version matches ns.VERSION", function()
        local toc = io.open("LedgerLink/LedgerLink.toc"):read("*a")
        assert.equals(ns.VERSION, toc:match("## Version: (%S+)"))
        assert.truthy(toc:find("## Interface: 16001", 1, true))
    end)
end)
