-- The char section's optional `data.mailworthy` block (Raid Ledger ROK-2148,
-- contract v1 CONTRACT.md §3.1), copied from the Mailworthy addon's
-- MailworthyAPI.v1.GetGuildExport(guildName). contract_spec schema-validates
-- the golden-fixture cases (export_cases.lua); this spec checks the copy is
-- exact, that a missing or failing Mailworthy leaves the key out, and that a
-- newer Mailworthy's extra keys and over-cap lists are cut to the contract.
local loadAddon = require("spec.support.load_addon")
local importString = require("spec.support.import")
local exportCases = require("spec.support.export_cases")
local GUID = "Player-4395-0ABCDEF0"
local NOW = 1790000000 -- WowStub serverTime

local function charData(ns)
    local str = assert(ns.Export.Run("char"))
    return importString(str, { now = NOW + 60 }).groups[1].payloads[1].data, str
end

local function install(result)
    local calls = {}
    _G.MailworthyAPI = { v1 = { GetGuildExport = function(guild)
        calls[#calls + 1] = guild
        if type(result) == "function" then return result(guild) end
        return result
    end } }
    return calls
end

local function name(n) return string.rep("a", n) end

describe("char export: Mailworthy block", function()
    local ns
    before_each(function()
        ns = loadAddon()
    end)

    for _, fixture in ipairs({ "char-mailworthy", "char-mailworthy-template-only" }) do
        it("carries the " .. fixture .. " golden fixture's block unchanged", function()
            local block = exportCases.mailworthyFixture(fixture)
            local data = charData(ns)
            assert.same(block, data.mailworthy)
        end)
    end

    it("passes the player's guild name", function()
        local calls = install(nil)
        charData(ns)
        assert.same({ "Night Shift" }, calls)
    end)

    describe("leaves the key out", function()
        local function assertAbsent(data, str)
            assert.is_nil(data.mailworthy)
            assert.is_nil(str:find("mailworthy", 1, true))
            assert.equal(2, #data.gear) -- the rest of the export is untouched
        end

        it("without Mailworthy", function()
            assertAbsent(charData(ns))
        end)

        it("when MailworthyAPI has no v1 or no GetGuildExport", function()
            _G.MailworthyAPI = {}
            assertAbsent(charData(ns))
            _G.MailworthyAPI = { v1 = {} }
            assertAbsent(charData(ns))
            _G.MailworthyAPI = { v1 = "nope" }
            assertAbsent(charData(ns))
        end)

        it("when GetGuildExport errors", function()
            install(function() error("boom") end)
            assertAbsent(charData(ns))
        end)

        it("when MailworthyAPI.v1 itself errors on access", function()
            _G.MailworthyAPI = setmetatable({}, { __index = function() error("boom") end })
            assertAbsent(charData(ns))
        end)

        it("when GetGuildExport returns nil or a non-table", function()
            install(nil)
            assertAbsent(charData(ns))
            install("text")
            assertAbsent(charData(ns))
        end)

        it("when the character has no guild, without calling Mailworthy", function()
            local calls = install({ generatedAt = NOW, peers = { { name = "Member1", lastSeenAt = NOW } } })
            WowStub.state.guild = nil
            assertAbsent(charData(ns))
            assert.same({}, calls)
        end)

        it("when nothing valid is left (or generatedAt is bad)", function()
            install({ generatedAt = NOW, peers = {}, givers = {} })
            assertAbsent(charData(ns))
            install({ generatedAt = 0, peers = { { name = "Member1", lastSeenAt = NOW } } })
            assertAbsent(charData(ns))
            install({ generatedAt = NOW * 1000, peers = { { name = "Member1", lastSeenAt = NOW } } })
            assertAbsent(charData(ns))
        end)
    end)

    describe("clamps a newer Mailworthy to the contract", function()
        local Clean
        before_each(function() Clean = ns.Mailworthy.Clean end)

        it("copies only the keys the schema knows", function()
            local block = Clean({
                generatedAt = NOW, gold = 5, ledger = { {} }, caps = {},
                template = { rev = NOW - 10, author = "Member1", use = true,
                    rules = { { professionSkillLineId = 333, recipientName = "Member2", cap = 20, use = "x" } } },
                peers = { { name = "Member1", lastSeenAt = NOW, version = "0.31" } },
                givers = { { characterName = "Member1", itemsAllTime = 5, countingSince = NOW - 100, asOf = NOW,
                    gold = 99, counterparties = { "Member2" }, bags = {},
                    days = { { day = 20717, items = 5, gold = 1 } } } },
            })
            assert.same({
                generatedAt = NOW,
                template = { rev = NOW - 10, author = "Member1",
                    rules = { { professionSkillLineId = 333, recipientName = "Member2" } } },
                peers = { { name = "Member1", lastSeenAt = NOW } },
                givers = { { characterName = "Member1", itemsAllTime = 5, countingSince = NOW - 100, asOf = NOW,
                    days = { { day = 20717, items = 5 } } } },
            }, block)
        end)

        it("drops names over 48 characters, never shortening them", function()
            local accented = string.rep("\195\169", 48) -- 48 characters, 96 bytes
            local block = Clean({ generatedAt = NOW,
                template = { rev = NOW, author = name(48), rules = {
                    { professionSkillLineId = 333, recipientName = name(49) },
                    { professionSkillLineId = 171, recipientName = accented },
                    { professionSkillLineId = 164, recipientName = "" },
                } },
                peers = { { name = name(49), lastSeenAt = NOW }, { name = accented, lastSeenAt = NOW - 1 } },
                givers = { { characterName = accented .. "a", itemsAllTime = 1, countingSince = NOW, asOf = NOW,
                    days = {} } },
            })
            assert.equal(name(48), block.template.author)
            assert.same({ { professionSkillLineId = 171, recipientName = accented } }, block.template.rules)
            assert.same({ { name = accented, lastSeenAt = NOW - 1 } }, block.peers)
            assert.is_nil(block.givers)
            -- an over-long author drops the whole template
            assert.is_nil(Clean({ generatedAt = NOW, template = { rev = NOW, author = name(49), rules = {} } }))
        end)

        it("keeps at most 8 rules and sends an empty rule list as []", function()
            local rules = {}
            for i = 1, 10 do rules[i] = { professionSkillLineId = i, recipientName = "Member" .. i } end
            local block = Clean({ generatedAt = NOW, template = { rev = NOW, author = "Member1", rules = rules } })
            assert.equal(8, #block.template.rules)
            assert.equal(8, block.template.rules[8].professionSkillLineId)

            install({ generatedAt = NOW, template = { rev = NOW, author = "Member1", rules = {} } })
            local data, str = charData(ns)
            assert.same({}, data.mailworthy.template.rules)
            assert.truthy(require("spec.support.decode")(str).json:find('"rules":[]', 1, true))
        end)

        it("keeps the newest 1000 peers, newest first, one per name", function()
            local peers = {}
            for i = 1, 1100 do peers[i] = { name = "Member" .. i, lastSeenAt = NOW - 5000 + i } end
            peers[#peers + 1] = { name = "Member1100", lastSeenAt = NOW - 9000 } -- older duplicate
            local block = Clean({ generatedAt = NOW, peers = peers })
            assert.equal(1000, #block.peers)
            assert.same({ name = "Member1100", lastSeenAt = NOW - 3900 }, block.peers[1])
            assert.equal("Member101", block.peers[1000].name)
            for i = 2, #block.peers do assert.is_true(block.peers[i - 1].lastSeenAt >= block.peers[i].lastSeenAt) end
        end)

        it("keeps Mailworthy's first 200 givers", function()
            local givers = {}
            for i = 1, 230 do
                givers[i] = { characterName = "Member" .. i, itemsAllTime = 1000 - i, countingSince = NOW - 100,
                    asOf = NOW, days = {} }
            end
            local block = Clean({ generatedAt = NOW, givers = givers })
            assert.equal(200, #block.givers)
            assert.equal("Member1", block.givers[1].characterName)
            assert.equal("Member200", block.givers[200].characterName)
        end)

        it("keeps the newest 35 non-zero days, ascending, one per day", function()
            local days = {}
            for i = 1, 40 do days[#days + 1] = { day = 20740 - i, items = i } end
            days[#days + 1] = { day = 20739, items = 99 } -- duplicate day
            days[#days + 1] = { day = 20741, items = 0 }  -- zero
            days[#days + 1] = { day = -1, items = 3 }
            days[#days + 1] = { day = 20742, items = -3 }
            local block = Clean({ generatedAt = NOW, givers = { { characterName = "Member1", itemsAllTime = 900,
                countingSince = NOW - 100, asOf = NOW, days = days } } })
            local got = block.givers[1].days
            assert.equal(35, #got)
            assert.equal(20705, got[1].day)
            assert.equal(20739, got[35].day)
            for i = 2, #got do assert.is_true(got[i - 1].day < got[i].day) end
        end)

        it("drops entries with negative, missing or out-of-range numbers", function()
            local block = Clean({ generatedAt = NOW,
                template = { rev = NOW, author = "Member1", rules = { { professionSkillLineId = 0, recipientName = "A" },
                    { professionSkillLineId = -4, recipientName = "B" }, { recipientName = "C" } } },
                peers = { { name = "A", lastSeenAt = -1 }, { name = "B" }, { name = "C", lastSeenAt = NOW * 1000 } },
                givers = {
                    { characterName = "A", itemsAllTime = -1, countingSince = NOW, asOf = NOW, days = {} },
                    { characterName = "B", itemsAllTime = 1, countingSince = 0, asOf = NOW, days = {} },
                    { characterName = "C", itemsAllTime = 0 / 0, countingSince = NOW, asOf = NOW, days = {} },
                    { characterName = "D", itemsAllTime = 1, countingSince = NOW, days = {} },
                    { characterName = "E", itemsAllTime = 1, countingSince = NOW, asOf = NOW, days = "x" },
                },
            })
            assert.same({}, block.template.rules)
            assert.is_nil(block.peers)
            assert.same({ { characterName = "E", itemsAllTime = 1, countingSince = NOW, asOf = NOW, days = {} } },
                block.givers)
            assert.equal('[]', ns.Json.encode(block.givers[1].days)) -- required, so sent as [] when empty
        end)

        it("drops a giver whose asOf is after generatedAt", function()
            local block = Clean({ generatedAt = NOW, givers = {
                { characterName = "Member1", itemsAllTime = 1, countingSince = NOW - 9, asOf = NOW + 1, days = {} },
                { characterName = "Member2", itemsAllTime = 2, countingSince = NOW - 9, asOf = NOW, days = {} },
            } })
            assert.equal(1, #block.givers)
            assert.equal("Member2", block.givers[1].characterName)
        end)
    end)

    describe("every export path", function()
        local block
        before_each(function() block = exportCases.mailworthyFixture("char-mailworthy") end)

        it("Export all carries it in the char string", function()
            local tokens = assert(ns.Export.RunAll())
            local groups = importString(table.concat(tokens, "\n"), { now = NOW + 60 }).groups
            assert.equal("char", groups[1].section)
            assert.same(block, groups[1].payloads[1].data.mailworthy)
        end)

        it("the logout Outbox passes the cached guild name once the client dropped the guild", function()
            local calls = install(block)
            ns.Guild.OnEvent("PLAYER_ENTERING_WORLD")
            ns.Char.OnEvent("PLAYER_ENTERING_WORLD")
            local s = WowStub.state
            s.guild, s.guildRoster, s.gear, s.talentConfigId = nil, {}, {}, nil
            ns.Outbox.frame:GetScript("OnEvent")(ns.Outbox.frame, "PLAYER_LOGOUT")
            local entry = LedgerLinkDB.outbox[GUID]
            local groups = importString(entry.text, { now = NOW + 60 }).groups
            assert.same(block, groups[1].payloads[1].data.mailworthy)
            assert.equal("Night Shift", calls[#calls])
        end)
    end)
end)
