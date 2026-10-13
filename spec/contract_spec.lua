-- The addon must emit exactly the wire format Raid Ledger owns. contract/v1/ is
-- a pinned copy of Raid Ledger's packages/contract/ledgerlink/v1/ (see
-- AGENTS.md); refresh it only with tools/sync-contract.sh.
local exportCases = require("spec.support.export_cases")
local decode = require("spec.support.decode")
local importString = require("spec.support.import")
local dkjson = require("dkjson")

-- Runs a shell command; returns (succeeded, output). LuaJIT's popen():close()
-- does not report the exit status, so the command echoes it.
local function shell(cmd)
    local p = assert(io.popen(cmd .. " 2>&1; echo \"__exit=$?\""))
    local out = p:read("*a")
    p:close()
    local body, code = out:match("^(.-)__exit=(%d+)%s*$")
    return tonumber(code) == 0, body
end

describe("contract/v1", function()
    it("is pinned to a Raid Ledger commit", function()
        local f = assert(io.open("contract/v1/SOURCE"))
        local sha = f:read("*l")
        f:close()
        assert.truthy(sha and sha:match("^%x+$") and #sha == 40, "contract/v1/SOURCE must hold a full commit SHA")
    end)

    it("accepts every page of every addon-generated export string", function()
        local dir = os.tmpname()
        os.remove(dir)
        assert(shell("mkdir -p '" .. dir .. "'"))
        local files = {}
        for _, case in ipairs(exportCases.cases) do
            for i, page in ipairs(exportCases.run(case)) do
                local path = string.format("%s/%s-p%d.json", dir, case.name, i)
                local f = assert(io.open(path, "w"))
                f:write(decode(page).json) -- the exact JSON bytes the server parses
                f:close()
                files[#files + 1] = "'" .. path .. "'"
            end
        end
        local ok, out = shell("node tools/validate-contract.mjs " .. table.concat(files, " "))
        shell("rm -rf '" .. dir .. "'")
        assert(ok, "schema validation failed:\n" .. out)
    end)

    -- Fixture .json = { pages, payload } "as the server decodes it" (CONTRACT.md
    -- section 8): guild pages merged, WoW UI escapes stripped from display
    -- strings, char gear `link` replaced by itemId + bonusIds. The fields the
    -- server rewrites in the current fixtures are skipped; everything else must
    -- match the wire JSON exactly.
    local SERVER_NORMALISED = { char = { gear = true, lockouts = true } }

    local function readFile(path)
        local f = assert(io.open(path))
        local s = f:read("*a")
        f:close()
        return s
    end

    local function fixtures(dir)
        local ok, list = shell("ls " .. dir .. "/*.txt")
        local names = {}
        if ok then for txt in list:gmatch("[^\n]+") do names[#names + 1] = txt:gsub("%.txt$", "") end end
        return names
    end

    -- Runs import + schema check; returns the import result, or nil and the error code.
    -- ROK-1756: Raid Ledger pins its clock to one hour after the golden
    -- fixtures' export stamp (2026-09-21); real beta strings use the real clock.
    local FIXTURE_NOW = 1790000000 + 3600

    local function importAndValidate(paste, now)
        local ok, result = pcall(importString, paste, { now = now or FIXTURE_NOW })
        if not ok then return nil, assert(type(result) == "table" and result.code, tostring(result)) end
        local dir = os.tmpname()
        os.remove(dir)
        assert(shell("mkdir -p '" .. dir .. "'"))
        local files, pageSections, payloads = {}, {}, {}
        for _, g in ipairs(result.groups) do
            for i, json in ipairs(g.jsons) do
                local n = #files + 1
                files[n] = string.format("'%s/page%d.json'", dir, n)
                local f = assert(io.open(files[n]:sub(2, -2), "w"))
                f:write(json)
                f:close()
                pageSections[n], payloads[n] = g.sections[i], g.payloads[i]
            end
        end
        local valid = shell("node tools/validate-contract.mjs " .. table.concat(files, " "))
        shell("rm -rf '" .. dir .. "'")
        if not valid then return nil, "INVALID_PAYLOAD" end
        for i, payload in ipairs(payloads) do
            if payload.section ~= pageSections[i] then return nil, "INVALID_PAYLOAD" end
        end
        return result
    end

    local function merged(group)
        local first = group.payloads[1]
        if first.section ~= "guild" then return first end
        local members = {}
        for _, p in ipairs(group.payloads) do
            for _, m in ipairs(p.data.members) do members[#members + 1] = m end
        end
        first.data.members = members
        return first
    end

    it("has valid fixtures that decode to their expected payload", function()
        local names = fixtures("contract/v1/fixtures")
        assert.is_true(#names > 0, "no fixtures in contract/v1/fixtures")
        for _, name in ipairs(names) do
            local result, code = importAndValidate(readFile(name .. ".txt"))
            assert(result, name .. ": rejected with " .. tostring(code))
            local expected = dkjson.decode(readFile(name .. ".json"), 1, dkjson.null)
            -- Mixed paste (CONTRACT.md §8): { sections = { {section, pages, payload}, ... } }
            -- in canonical order char -> guild -> raid; single: { pages, payload }.
            local want = expected.sections or { { section = result.groups[1].section,
                pages = expected.pages, payload = expected.payload } }
            assert.equal(#want, #result.groups, name .. ": section count")
            for i, w in ipairs(want) do
                local g = result.groups[i]
                assert.equal(w.section, g.section, name)
                assert.equal(w.pages, g.pages, name .. " " .. g.section)
                local got = merged(g)
                for field in pairs(SERVER_NORMALISED[got.section] or {}) do
                    got.data[field], w.payload.data[field] = nil, nil
                end
                assert.same(w.payload, got, name .. " " .. g.section)
            end
        end
    end)

    -- CONTRACT §3: tree/row/col hints must equal the posX/posY derivation. Runs
    -- the addon's TalentGrid over every fixture node set, so a drifted hint on
    -- either side fails here (the pre-ROK-1758 char-forever-talents-named did).
    it("has talent hints in every fixture that match TalentGrid's posX/posY derivation", function()
        local grid = require("spec.support.load_addon")().TalentGrid
        local checked = 0
        for _, name in ipairs(fixtures("contract/v1/fixtures")) do
            local expected = dkjson.decode(readFile(name .. ".json"), 1, dkjson.null)
            local payloads = {}
            if expected.sections then
                for _, sec in ipairs(expected.sections) do payloads[#payloads + 1] = sec.payload end
            else
                payloads[1] = expected.payload
            end
            for _, p in ipairs(payloads) do
                local nodes = p.section == "char" and p.data.talents and p.data.talents.nodes or {}
                local copies, hinted = {}, false
                for i, n in ipairs(nodes) do
                    copies[i] = { posX = n.posX, posY = n.posY }
                    hinted = hinted or n.tree ~= nil
                end
                if hinted then
                    grid.Assign(copies)
                    for i, n in ipairs(nodes) do
                        if n.tree ~= nil then
                            assert.same({ n.tree, n.row, n.col }, { copies[i].tree, copies[i].row, copies[i].col },
                                string.format("%s node %s", name, tostring(n.nodeId)))
                            checked = checked + 1
                        end
                    end
                end
            end
        end
        assert.is_true(checked > 0, "no fixture carries talent hints")
    end)

    -- ROK-1760: the server's decoded gear `name` is parsed from the raw link the
    -- addon sends ("|h[Name]|h"), so each fixture's decoded name must appear
    -- bracketed in the matching raw link.
    it("has decoded gear names that come from the raw item links", function()
        local checked = 0
        for _, name in ipairs(fixtures("contract/v1/fixtures")) do
            local expected = dkjson.decode(readFile(name .. ".json"), 1, dkjson.null)
            local result = importString(readFile(name .. ".txt"))
            local want = expected.sections or { { section = result.groups[1].section, payload = expected.payload } }
            for _, sec in ipairs(want) do
                if sec.section == "char" then
                    local raw
                    for _, g in ipairs(result.groups) do if g.section == "char" then raw = g.payloads[1] end end
                    for i, item in ipairs(sec.payload.data.gear) do
                        if type(item.name) == "string" then
                            local link = raw.data.gear[i].link
                            assert(type(link) == "string" and link:find("[" .. item.name .. "]", 1, true),
                                string.format("%s gear %d: %q not in link", name, i, item.name))
                            checked = checked + 1
                        end
                    end
                end
            end
        end
        assert.is_true(checked > 0, "no fixture carries decoded gear names")
    end)

    it("accepts every anonymised real string from the beta (spec/fixtures/beta)", function()
        local names = fixtures("spec/fixtures/beta")
        assert.is_true(#names > 0, "no fixtures in spec/fixtures/beta")
        for _, name in ipairs(names) do
            local result, code = importAndValidate(readFile(name .. ".txt"), os.time())
            assert(result, name .. ": rejected with " .. tostring(code))
        end
    end)

    it("rejects every invalid fixture with the server's error code", function()
        local names = fixtures("contract/v1/fixtures/invalid")
        assert.is_true(#names > 0, "no fixtures in contract/v1/fixtures/invalid")
        for _, name in ipairs(names) do
            local result, code = importAndValidate(readFile(name .. ".txt"))
            local expected = dkjson.decode(readFile(name .. ".json")).code
            assert(not result, name .. ": accepted, expected " .. expected)
            assert.equal(expected, code, name)
        end
    end)
end)
