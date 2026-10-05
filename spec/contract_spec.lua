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
    local function importAndValidate(paste)
        local ok, result = pcall(importString, paste)
        if not ok then return nil, assert(type(result) == "table" and result.code, tostring(result)) end
        local dir = os.tmpname()
        os.remove(dir)
        assert(shell("mkdir -p '" .. dir .. "'"))
        local files = {}
        for i, json in ipairs(result.jsons) do
            files[i] = string.format("'%s/page%d.json'", dir, i)
            local f = assert(io.open(files[i]:sub(2, -2), "w"))
            f:write(json)
            f:close()
        end
        local valid = shell("node tools/validate-contract.mjs " .. table.concat(files, " "))
        shell("rm -rf '" .. dir .. "'")
        if not valid then return nil, "INVALID_PAYLOAD" end
        for i, payload in ipairs(result.payloads) do
            if payload.section ~= result.sections[i] then return nil, "INVALID_PAYLOAD" end
        end
        return result
    end

    local function merged(result)
        local first = result.payloads[1]
        if first.section ~= "guild" then return first end
        local members = {}
        for _, p in ipairs(result.payloads) do
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
            assert.equal(expected.pages, result.pages, name)
            local got, want = merged(result), expected.payload
            for field in pairs(SERVER_NORMALISED[got.section] or {}) do
                got.data[field], want.data[field] = nil, nil
            end
            assert.same(want, got, name)
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
