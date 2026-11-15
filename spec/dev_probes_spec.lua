-- /rl dev probes (Raid Ledger ROK-2190): the Companion's DevQueue.lua is read
-- only in dev mode; each probe runs after its event, every `fn` passes the
-- pinned allowlist first, and the answer is LedgerLinkDB.dev.probes[probeId],
-- a probe-result JSON string. Shapes: contract/dev-bridge/v1 (pinned).
local loadAddon = require("spec.support.load_addon")
local dkjson = require("dkjson")
local gen = require("tools.gen_dev_allowlist")

local V1 = "contract/dev-bridge/v1/"
local FIXTURES = V1 .. "fixtures/"
local PROBE_ID = "01JBX7Q2M3N4P5R6S7T8V9W0XY" -- the fixtures' ids
local STUBBED = { "GetNumSkillLines", "GetSkillLineInfo", "GetCVar", "SendChatMessage", "GetDeepTable",
    "GetManyValues", "GetBigValue", "GetCount", "GetBoom", "GetUtf8", "C_Probe" }

local function read(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

local function decode(json)
    local value, _, err = dkjson.decode(json, 1, dkjson.null)
    assert(value, err)
    return value
end

-- Runs a shell command; returns (succeeded, output). LuaJIT's popen():close()
-- does not report the exit status, so the command echoes it.
local function shell(cmd)
    local p = assert(io.popen(cmd .. " 2>&1; echo \"__exit=$?\""))
    local out = p:read("*a")
    p:close()
    local body, code = out:match("^(.-)__exit=(%d+)%s*$")
    return tonumber(code) == 0, body
end

--- Validate JSON texts against the pinned schema's $defs/<def> (ajv); returns (ok, output).
local function validate(def, texts)
    local paths = {}
    for i, text in ipairs(texts) do
        paths[i] = os.tmpname()
        local f = assert(io.open(paths[i], "wb"))
        f:write(text)
        f:close()
    end
    local ok, out = shell("node tools/validate-contract.mjs --dev-bridge " .. def .. " '"
        .. table.concat(paths, "' '") .. "'")
    for _, path in ipairs(paths) do os.remove(path) end
    return ok, out
end

local function assertPinned(def, texts, label)
    local ok, out = validate(def, texts)
    assert(ok, label .. " violates contract/dev-bridge/v1 $defs/" .. def .. ":\n" .. out)
end

local function utf8Units(s)
    local units = 0
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do units = units + (#c == 4 and 2 or 1) end
    return units
end

--- The byte caps schema.json cannot carry (Zod-only): whole ≤ 64 KiB, each item ≤ 3 KiB.
--- Returns nil, or the first broken cap.
local function capProblem(ns, json)
    local Json = ns.Json
    if #json > 65536 then return "whole result is " .. #json .. " bytes" end
    local result = Json.decode(json)
    for index, call in ipairs(result.calls) do
        local iterations = call.iterations
        call.iterations = nil
        if #Json.encode(call) > 3072 then return "calls." .. (index - 1) .. " is over 3 KiB" end
        for k, iteration in ipairs(iterations or {}) do
            if #Json.encode(iteration) > 3072 then return "calls." .. (index - 1) .. ".iterations." .. (k - 1) end
        end
    end
    return nil
end

--- The Lua file the Companion writes: one long-bracket string the JSON cannot close.
local function queueFile(json)
    local level = 0
    while json:find("]" .. string.rep("=", level) .. "]", 1, true) do level = level + 1 end
    local eq = string.rep("=", level)
    return "RaidLedgerProbeQueue = [" .. eq .. "[" .. json .. "]" .. eq .. "]\n"
end

--- Install a queue the way the client loads DevQueue.lua after the Companion wrote it.
local function installQueue(json)
    assert(loadstring(queueFile(json), "DevQueue.lua"))()
end

local function queueOf(entries)
    return dkjson.encode({ queueVersion = 1, probes = entries })
end

local function fire(ns, event)
    assert.is_true(ns.DevProbes.frame.events[event], event .. " not registered")
    ns.DevProbes.frame:GetScript("OnEvent")(ns.DevProbes.frame, event)
end

local function result(id)
    local json = LedgerLinkDB.dev.probes[id or PROBE_ID]
    assert.is_string(json)
    return json, decode(json)
end

--- A probe-request fixture as the Companion would queue it.
local function entryOf(request, probeId)
    local entry = {}
    for k, v in pairs(request) do entry[k] = v end
    entry.probeId, entry.flavor = probeId or PROBE_ID, "_anniversary_"
    entry.after = entry.after or "PLAYER_LOGIN"
    entry.ttlHours = entry.ttlHours or 72
    return entry
end

local function call(id, fn, extra)
    local c = { id = id, fn = fn }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function probe(calls, extra)
    local e = { probeId = PROBE_ID, title = "Spec probe", flavor = "_anniversary_", after = "PLAYER_LOGIN",
        ttlHours = 72, calls = calls }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end

describe("/rl dev probes", function()
    local ns, queuedAt, realTime

    before_each(function()
        ns = loadAddon()
        realTime = _G.time
        queuedAt = ns.DevProbes.QueuedAt(PROBE_ID)
        _G.time = function(t) if t then return realTime(t) end return queuedAt + 3600 end
        _G.GetNumSkillLines = function() return 2 end
        _G.GetSkillLineInfo = function(i)
            if i == 1 then return "Professions", true, false, 0, 0, 0, 0 end
            return "Herbalism", false, false, 112, 0, 0, 300
        end
        _G.GetCVar = function(...) return ... end
    end)

    after_each(function()
        _G.time = realTime
        for _, name in ipairs(STUBBED) do _G[name] = nil end
        _G.RaidLedgerProbeQueue = nil
        setmetatable(_G, nil)
    end)

    local function devOn(json)
        ns.DevSnapshot.SetEnabled(true)
        if json then installQueue(json) end
        return ns.DevProbes.Load()
    end

    describe("pinned allowlist", function()
        it("DevAllowlist.lua is generated from the pinned allowlist.json (re-run tools/gen_dev_allowlist.lua)", function()
            assert.equal(gen.expected(), read(gen.TARGET))
        end)

        local allowlist = decode(read(V1 .. "allowlist.json"))

        it("splits words exactly as the tokenizer vectors say", function()
            for _, case in ipairs(allowlist.examples.tokenizer) do
                assert.same(case.words, ns.DevProbes.Words(case.segment), case.segment)
            end
        end)

        it("agrees with every shared example: allowed, denied and deny-listed", function()
            for _, path in ipairs(allowlist.examples.allowed) do
                assert.is_true(ns.DevProbes.Check(path), path)
            end
            for _, list in ipairs({ allowlist.examples.denied, allowlist.examples.denyListed }) do
                for _, path in ipairs(list) do
                    local ok, why = ns.DevProbes.Check(path)
                    assert.is_false(ok, path)
                    assert.is_string(why)
                end
            end
        end)
    end)

    describe("JSON reader", function()
        it("decodes every probe fixture and re-encodes it to the byte count devBridgeJsonBytes gives", function()
            local names = {}
            for name in io.popen("ls " .. FIXTURES .. " | grep '^probe-'"):lines() do names[#names + 1] = name end
            assert.is_true(#names >= 10, "too few probe fixtures")
            local ok, out = shell("node -e 'for (const f of process.argv.slice(1)) console.log(Buffer.byteLength("
                .. "JSON.stringify(JSON.parse(require(\"fs\").readFileSync(f, \"utf8\")))))' "
                .. FIXTURES .. table.concat(names, " " .. FIXTURES))
            assert(ok, out)
            local i = 0
            for line in out:gmatch("[^\n]+") do
                i = i + 1
                assert.equal(tonumber(line), #ns.Json.encode(ns.Json.decode(read(FIXTURES .. names[i]))), names[i])
            end
            assert.equal(#names, i)
        end)

        it("handles escapes, surrogate pairs and nulls, and refuses malformed text", function()
            local v = ns.Json.decode('{"a":"\\u00e9\\ud83d\\ude00\\n\\"\\/","b":[null,1.5e2,-3,true],"c":[]}')
            assert.equal("é😀\n\"/", v.a)
            assert.is_true(ns.Json.isArray(v.b) and ns.Json.isArray(v.c))
            assert.equal(ns.Json.null, v.b[1])
            assert.equal(150, v.b[2])
            for _, bad in ipairs({ "", "{", '{"a":1,}', "[1 2]", '"raw\ncontrol"', "nul", "1 2", '{"a":1e999}',
                string.rep("[", 40) .. string.rep("]", 40) }) do
                assert.is_false(pcall(ns.Json.decode, bad), bad)
            end
        end)
    end)

    describe("the queue", function()
        it("answers both probe-queue.json probes after their events, matching the pinned schema", function()
            local queue = read(FIXTURES .. "probe-queue.json")
            assert.equal(2, devOn(queue))
            fire(ns, "PLAYER_LOGIN")
            assert.equal(1, ns.DevProbes.Count())
            fire(ns, "PLAYER_ENTERING_WORLD")
            assert.equal(2, ns.DevProbes.Count())
            assert.truthy(WowStub.printed[#WowStub.printed]:find("Answered 1 dev probe(s)", 1, true))

            local first, decoded = result()
            local expected = decode(read(FIXTURES .. "probe-result--professions.json"))
            expected.capturedAt, expected.addonVersion = decoded.capturedAt, decoded.addonVersion
            assert.same(expected, decoded)
            assert.equal("0.0.0-dev", decoded.addonVersion)

            -- The quoted CVar arg (]] ]==] " newline backslash) reaches the call byte for byte.
            local second, cvar = result("01JBX7Q2M3N4P5R6S7T8V9W0XZ")
            assert.same({ "a]]b]==]c\"d\ne\\f", "it's" }, cvar.calls[1].values)
            assertPinned("probe-result", { first, second }, "the probe-queue.json results")
        end)

        it("runs the largest request (probe-request--max-size) and the 4 KiB queue entry", function()
            local request = decode(read(FIXTURES .. "probe-request--max-size.json"))
            local maxEntry = decode(read(FIXTURES .. "probe-queue--max-entry.json")).probes[1]
            maxEntry.probeId = "01JBX7Q2M3N4P5R6S7T8V9W0XZ"
            assert.equal(2, devOn(queueOf({ entryOf(request), maxEntry })))
            fire(ns, "PLAYER_LOGIN")
            assert.equal(2, ns.DevProbes.Count())
            local a = result()
            local b = result(maxEntry.probeId)
            assertPinned("probe-result", { a, b }, "the max-size results")
            assert.is_nil(capProblem(ns, a))
            assert.is_nil(capProblem(ns, b))
        end)

        it("refuses each invalid probe-queue fixture at the entry the contract names", function()
            local cases = {
                ["probe-queue--flavor-auto"] = { refused = 1, kept = 1 },
                ["probe-queue--missing-probe-id"] = { refused = 2, kept = 1 },
                ["probe-queue--missing-ttl"] = { refused = 1, kept = 1 },
            }
            local expected = decode(read(FIXTURES .. "invalid/EXPECTED.json"))
            ns.DevSnapshot.SetEnabled(true)
            installQueue(read(FIXTURES .. "invalid/probe-queue--missing-ttl.json"))
            assert.equal(1, ns.DevProbes.Load()) -- its other probe is valid
            assert.truthy(WowStub.printed[#WowStub.printed]:find("1 entry refused (probe 1: ttlHours", 1, true))
            for name, case in pairs(cases) do
                assert.truthy(expected[name], name)
                local entries, refused = ns.DevProbes.ParseQueue(read(FIXTURES .. "invalid/" .. name .. ".json"))
                assert.equal(case.kept, #entries, name)
                assert.equal(1, #refused, name)
                assert.equal(case.refused, refused[1].index, name)
                assert.equal(tonumber(expected[name].path:match("^probes%.(%d+)")) + 1, refused[1].index, name)
            end
        end)

        it("every invalid probe-request is refused, or (allowlist issues) answered with that call denied", function()
            local expected = decode(read(FIXTURES .. "invalid/EXPECTED.json"))
            local texts, denied, refused = {}, 0, 0
            for name, issue in pairs(expected) do
                if name:match("^probe%-request") then
                    local entry = entryOf(decode(read(FIXTURES .. "invalid/" .. name .. ".json")))
                    local index = issue.code == "custom" and issue.path:match("^calls%.(%d+)%.fn$")
                    local why = ns.DevProbes.CheckEntry(ns.Json.decode(dkjson.encode(entry)))
                    if index then
                        assert.is_nil(why, name)
                        local res = ns.DevProbes.Run(ns.Json.decode(dkjson.encode(entry)))
                        assert.equal("denied", res.calls[tonumber(index) + 1].status, name)
                        texts[#texts + 1] = ns.Json.encode(res)
                        denied = denied + 1
                    else
                        assert.is_string(why, name .. " should be refused")
                        refused = refused + 1
                    end
                end
            end
            assert.is_true(denied >= 10 and refused >= 10, denied .. " denied, " .. refused .. " refused")
            assertPinned("probe-result", texts, "the denied results")
        end)

        it("the probe-result fixtures pass the pinned schema and the caps; the invalid ones do not", function()
            for _, name in ipairs({ "probe-result--professions", "probe-result--nested-tables" }) do
                local text = read(FIXTURES .. name .. ".json")
                assertPinned("probe-result", { text }, name)
                assert.is_nil(capProblem(ns, text), name)
            end
            assert.equal("calls.1 is over 3 KiB",
                capProblem(ns, read(FIXTURES .. "invalid/probe-result--item-too-big.json")))
            for _, name in ipairs({ "probe-result--string-too-long", "probe-result--unknown-status" }) do
                assert.is_false(validate("probe-result", { read(FIXTURES .. "invalid/" .. name .. ".json") }), name)
            end
        end)
    end)

    describe("dev mode", function()
        it("off: the queue is never read and nothing runs or is stored", function()
            local reads = 0
            setmetatable(_G, { __index = function(_, k) if k == "RaidLedgerProbeQueue" then reads = reads + 1 end end })
            _G.RaidLedgerProbeQueue = nil -- leave it to __index
            ns.Init()
            assert.equal(0, ns.DevProbes.Load())
            for _, event in ipairs(ns.DevProbes.EVENTS) do fire(ns, event) end
            assert.equal(0, reads)
            assert.is_nil(LedgerLinkDB.dev)
            -- Even with a queue loaded: no dev mode, no reads, no results.
            setmetatable(_G, nil)
            installQueue(read(FIXTURES .. "probe-queue.json"))
            assert.equal(0, ns.DevProbes.Load())
            fire(ns, "PLAYER_LOGIN")
            assert.is_nil(LedgerLinkDB.dev)
        end)

        it("/rl dev off mid-session stops pending probes and removes stored results", function()
            devOn(read(FIXTURES .. "probe-queue.json"))
            fire(ns, "PLAYER_LOGIN")
            assert.equal(1, ns.DevProbes.Count())
            ns.HandleSlash("dev off")
            fire(ns, "PLAYER_ENTERING_WORLD")
            assert.is_nil(LedgerLinkDB.dev)
        end)

        it("Init reads the queue (ADDON_LOADED) when dev mode is on", function()
            ns.DevSnapshot.SetEnabled(true)
            installQueue(read(FIXTURES .. "probe-queue.json"))
            ns.Init()
            assert.equal(2, #ns.DevProbes.pending)
        end)
    end)

    describe("calls", function()
        it("reports a denied call as denied and never calls it; name-bearing fn is denied, presence works", function()
            local sent = 0
            _G.SendChatMessage = function() sent = sent + 1 end
            devOn(queueOf({ probe({ call("chat", "SendChatMessage", { args = { "hi", "SAY" } }),
                call("name", "UnitName", { args = { "player" } }), { id = "nameType", presence = "UnitName" },
                call("rl", "C_GuildInfo.GetGuildRosterLastOnline") }) }))
            fire(ns, "PLAYER_LOGIN")
            local json, r = result()
            assert.equal(0, sent)
            assert.same({ "denied", "denied", "ok", "denied" },
                { r.calls[1].status, r.calls[2].status, r.calls[3].status, r.calls[4].status })
            assert.truthy(r.calls[2].error:find("name-bearing", 1, true))
            assert.truthy(r.calls[4].error:find("name-bearing", 1, true))
            assert.same({ "function" }, r.calls[3].values)
            assert.is_nil(json:find("Ana", 1, true))
            assertPinned("probe-result", { json }, "the denied probe")
        end)

        it("a forEach over a denied fn is denied without iterations", function()
            _G.SendChatMessage = function() error("must not run") end
            devOn(queueOf({ probe({ call("n", "GetNumSkillLines"),
                call("loop", "SendChatMessage", { args = { "$i" }, forEach = { countFrom = "n", max = 5 } }) }) }))
            fire(ns, "PLAYER_LOGIN")
            local _, r = result()
            assert.equal("denied", r.calls[2].status)
            assert.is_nil(r.calls[2].iterations)
        end)

        it("missing, error and a non-number countFrom", function()
            _G.GetBoom = function() error("boom Player-4395-0ABCDEF0") end
            _G.GetCount = function() return "two" end
            devOn(queueOf({ probe({ call("missing", "GetNothingHere"), call("boom", "GetBoom"), call("c", "GetCount"),
                call("loop", "GetSkillLineInfo", { args = { "$i" }, forEach = { countFrom = "c", max = 3 } }) }) }))
            fire(ns, "PLAYER_LOGIN")
            local json, r = result()
            assert.same({ "missing", "error", "ok", "error" },
                { r.calls[1].status, r.calls[2].status, r.calls[3].status, r.calls[4].status })
            assert.truthy(r.calls[2].error:find("boom <guid>", 1, true))
            assertPinned("probe-result", { json }, "the failing probe")
        end)

        it("waits for its event, skips expired and answered probes", function()
            local later = "01JBX7Q2M3N4P5R6S7T8V9W0Y0"
            devOn(queueOf({ probe({ call("n", "GetNumSkillLines") }, { after = "GUILD_ROSTER_UPDATE" }),
                probe({ call("n", "GetNumSkillLines") }, { probeId = later, ttlHours = 1 }) }))
            -- `later` was queued at queuedAt; now is queuedAt + 1 h + 1 s: its 1 h TTL is past.
            _G.time = function(t) if t then return realTime(t) end return queuedAt + 3601 end
            fire(ns, "PLAYER_LOGIN")
            fire(ns, "PLAYER_ENTERING_WORLD")
            assert.equal(0, ns.DevProbes.Count())
            fire(ns, "GUILD_ROSTER_UPDATE")
            assert.equal(1, ns.DevProbes.Count())
            -- Next load: answered already, so nothing waits.
            assert.equal(0, ns.DevProbes.Load())
        end)

        it("keeps at most 50 results and prunes those past the longest TTL", function()
            ns.DevSnapshot.SetEnabled(true)
            local probes, ids = LedgerLinkDB.dev.probes, {}
            local alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
            for i = 1, 60 do
                local id = "01JBX7Q2M3" .. alphabet:sub(math.floor(i / 32) + 1, math.floor(i / 32) + 1)
                    .. alphabet:sub(i % 32 + 1, i % 32 + 1) .. string.rep("0", 14)
                ids[i], probes[id] = id, "{}"
            end
            probes["01AAAAAAAA0000000000000000"] = "{}" -- queued long ago
            probes["not-a-ulid"] = "{}"
            ns.DevProbes.Prune()
            assert.equal(50, ns.DevProbes.Count())
            assert.is_nil(probes[ids[10]])
            assert.is_string(probes[ids[11]])
            assert.is_string(probes[ids[60]])
        end)
    end)

    describe("caps", function()
        it("values: ≤40 returns, strings ≤512, tables 3 deep and ≤40 entries; each item ≤3 KiB", function()
            _G.GetManyValues = function()
                local out = {}
                for i = 1, 60 do out[i] = string.rep("x", 600) end
                return unpack(out)
            end
            _G.GetDeepTable = function()
                local wide = {}
                for i = 1, 50 do wide[i] = i end
                return { a = { b = { c = { d = "too deep" } } }, wide = wide }
            end
            _G.GetUtf8 = function() return "é😀\1\"\n" end
            devOn(queueOf({ probe({ call("many", "GetManyValues"), call("deep", "GetDeepTable"),
                call("utf", "GetUtf8") }) }))
            fire(ns, "PLAYER_LOGIN")
            local json, r = result()
            assert.is_true(r.truncated)
            assert.is_true(r.calls[1].truncated)
            assert.is_true(#r.calls[1].values >= 1 and #r.calls[1].values <= 40)
            for _, v in ipairs(r.calls[1].values) do assert.is_true(utf8Units(v) <= 512) end
            assert.is_true(r.calls[2].truncated)
            assert.equal("{...}", r.calls[2].values[1].a.b.c)
            assert.equal(40, #r.calls[2].values[1].wide)
            assert.equal("é😀\1\"\n", r.calls[3].values[1])
            assert.is_nil(capProblem(ns, json))
            assertPinned("probe-result", { json }, "the capped values")
            -- Our byte count is node's (devBridgeJsonBytes: JSON.stringify, then UTF-8).
            local path = os.tmpname()
            local f = assert(io.open(path, "wb"))
            f:write(json)
            f:close()
            local ok, out = shell("node -e 'console.log(Buffer.byteLength(JSON.stringify(JSON.parse("
                .. "require(\"fs\").readFileSync(process.argv[1], \"utf8\")))))' " .. path)
            os.remove(path)
            assert(ok, out)
            assert.equal(#json, tonumber(out))
        end)

        it("a lone value over 3 KiB is dropped (values = [])", function()
            _G.GetBigValue = function()
                local t = {}
                for i = 1, 40 do t[i] = string.rep("\1", 80) end
                return t
            end
            devOn(queueOf({ probe({ call("big", "GetBigValue") }) }))
            fire(ns, "PLAYER_LOGIN")
            local json, r = result()
            assert.same({}, r.calls[1].values)
            assert.is_true(r.calls[1].truncated and r.truncated)
            assertPinned("probe-result", { json }, "the dropped value")
        end)

        it("the whole result stays ≤64 KiB: iterations stop, and all 40 calls are still listed", function()
            local big = string.rep("\1", 80) -- 480 bytes encoded, so 6 of them fill an item
            _G.C_Probe = {
                GetCount = function() return 200 end,
                GetRow = function() return big, big, big, big, big, big end,
            }
            local calls = { call("n", "C_Probe.GetCount") }
            for i = 1, 39 do
                calls[#calls + 1] = call("row" .. i, "C_Probe.GetRow", { args = { "$i" },
                    forEach = { countFrom = "n", max = 200 } })
            end
            devOn(queueOf({ probe(calls) }))
            fire(ns, "PLAYER_LOGIN")
            local json, r = result()
            assert.is_true(#json <= 65536, #json .. " bytes")
            assert.is_true(#json > 60000, "the budget should be nearly used: " .. #json)
            assert.equal(40, #r.calls)
            assert.is_true(r.truncated)
            assert.is_true(r.calls[2].truncated)
            assert.is_true(#r.calls[2].iterations > 0)
            assert.is_true(r.calls[40].truncated)
            assert.equal(0, #(r.calls[40].iterations or {}))
            assert.is_nil(capProblem(ns, json))
            assertPinned("probe-result", { json }, "the 64 KiB result")
        end)
    end)

    it("addonVersion is the contract's semver: the packaged tag without its v, else 0.0.0-dev", function()
        for version, expected in pairs({ ["v1.6.0"] = "1.6.0", ["1.6.0-beta.2"] = "1.6.0-beta.2",
            ["v1.6.0-3-gabc123"] = "1.6.0-3-gabc123", ["@project-version@"] = "0.0.0-dev", ["v1.6"] = "0.0.0-dev",
            ["12345.1.1"] = "0.0.0-dev" }) do
            ns.VERSION = version
            assert.equal(expected, ns.DevProbes.AddonVersion(), version)
        end
    end)
end)
