-- /rl dev (Raid Ledger ROK-2072): a diagnostic snapshot stored in
-- LedgerLinkDB.dev.snapshots[guid] on PLAYER_LOGOUT while dev mode is on.
-- Shape: Raid Ledger dev-bridge/v1 `ledgerlink-snapshot` (spec section 4).
local loadAddon = require("spec.support.load_addon")
local dkjson = require("dkjson")

local GUID = "Player-4395-0ABCDEF0"

local function logout(ns)
    assert.is_true(ns.DevSnapshot.frame.events.PLAYER_LOGOUT)
    ns.DevSnapshot.frame:GetScript("OnEvent")(ns.DevSnapshot.frame, "PLAYER_LOGOUT")
end

local function stored()
    return LedgerLinkDB.dev.snapshots[GUID]
end

local function decode(json)
    local value, _, err = dkjson.decode(json, 1, dkjson.null)
    assert(value, err)
    return value
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
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

--- The stored JSON must pass ajv against the pinned Raid Ledger schema
--- (contract/dev-bridge/v1, a copy refreshed only by tools/sync-contract.sh).
local function assertPinnedSchema(json, label)
    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write(json)
    f:close()
    local ok, out = shell("node tools/validate-contract.mjs --dev-bridge ledgerlink-snapshot '" .. path .. "'")
    os.remove(path)
    assert(ok, label .. " violates contract/dev-bridge/v1 $defs/ledgerlink-snapshot:\n" .. out)
end

local function keysExactly(t, expected, label)
    for k in pairs(t) do assert(expected[k], label .. ": unexpected key " .. tostring(k)) end
end

local function set(list)
    local out = {}
    for _, k in ipairs(list) do out[k] = true end
    return out
end

--- dkjson value -> the addon's Json tables (arrays marked), so Json.encode measures it.
local function addonValue(Json, v)
    if v == dkjson.null then return Json.null end
    if type(v) ~= "table" then return v end
    local mt = getmetatable(v)
    local out = (mt and mt.__jsontype == "array") and Json.array() or {}
    for k, x in pairs(v) do out[k] = addonValue(Json, x) end
    return out
end

local TOP = set({ "snapshotVersion", "addonVersion", "capturedAt", "trigger", "client", "character", "ruleset",
    "calls", "apis", "sections", "truncated" })
local LUA_TYPES = set({ "nil", "function", "table", "string", "number", "boolean", "userdata", "thread" })

--- The section 4 shape and caps, checked on the stored string.
local function assertShape(ns, json)
    local Json, decoded = ns.Json, decode(json)
    local snap = addonValue(Json, decoded)
    assert.equal(json, Json.encode(snap)) -- the round trip is exact, so the byte counts below are real
    keysExactly(snap, TOP, "snapshot")
    assert.equal(1, snap.snapshotVersion)
    assert.equal("logout", snap.trigger)
    assert.truthy(snap.capturedAt:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"), snap.capturedAt)
    keysExactly(snap.client, set({ "version", "build", "buildDate", "interface", "tocInterface", "locale", "region" }),
        "client")
    keysExactly(snap.character, set({ "class", "level", "faction", "inGuild" }), "character")
    keysExactly(snap.ruleset, set({ "isGameRuleActive", "enumGameRule", "rules", "rulesTruncated", "ledgerLink" }),
        "ruleset")
    assert.is_true(#snap.calls <= 40 and #snap.apis <= 160 and #snap.sections <= 9)
    for _, item in ipairs(snap.calls) do
        keysExactly(item, set({ "fn", "args", "status", "type", "values", "error", "truncated" }), "call " .. item.fn)
        assert.equal(item.status == "presence", item.type ~= nil, item.fn)
        assert.is_true(#Json.encode(item) <= 3072)
    end
    local previous
    for _, item in ipairs(snap.apis) do
        keysExactly(item, set({ "path", "type" }), "api")
        assert.truthy(LUA_TYPES[item.type], item.path)
        assert(previous == nil or previous < item.path, "apis not sorted/unique at " .. item.path)
        previous = item.path
    end
    for _, item in ipairs(snap.sections) do
        keysExactly(item, set({ "id", "status", "lines", "error", "truncated" }), "section")
        assert.is_true(#item.lines <= 40 and #Json.encode(item) <= 3072)
        for _, line in ipairs(item.lines) do assert.is_true(#line <= 256) end
    end
    local head = {}
    for k, v in pairs(snap) do if k ~= "calls" and k ~= "apis" and k ~= "sections" then head[k] = v end end
    assert.is_true(#Json.encode(head) <= 4096)
    assert.is_true(#json <= 49152)
    assert.is_nil(json:find("Player%-%d+%-%x+"), "a GUID is in the snapshot")
    return decoded
end

describe("/rl dev snapshot", function()
    local ns
    before_each(function() ns = loadAddon() end)
    after_each(function() _G.C_GameRules, _G.UnitSex, _G.C_QuestLog = nil, nil, nil end)

    it("is off by default: no dev key after Init and PLAYER_LOGOUT", function()
        logout(ns)
        assert.is_nil(LedgerLinkDB.dev)
        assert.is_false(ns.DevSnapshot.OnLogout())
    end)

    it("stores one snapshot string per character on PLAYER_LOGOUT once on, matching the shape", function()
        ns.HandleSlash("dev on")
        assert.truthy(WowStub.printed[#WowStub.printed]:find("Dev snapshot on", 1, true))
        logout(ns)
        assert.equal(1, count(LedgerLinkDB.dev.snapshots))
        assert.is_string(stored())
        local snap = assertShape(ns, stored())
        assertPinnedSchema(stored(), "the normal snapshot")
        assert.equal("1.60.1", snap.client.version)
        assert.equal("70009", snap.client.build)
        assert.equal(16001, snap.client.interface)
        assert.equal(16001, snap.client.tocInterface)
        assert.equal(1, snap.client.region)
        assert.same({ class = "PALADIN", level = 60, faction = "Alliance", inGuild = true }, snap.character)
        assert.equal(ns.VERSION, snap.addonVersion)
        assert.same({ "S3", "S9" }, { snap.sections[1].id, snap.sections[2].id })
        assert.equal("ok", snap.sections[1].status)
    end)

    it("/rl dev off removes every saved snapshot; /rl dev reports the state", function()
        ns.HandleSlash("dev on")
        logout(ns)
        ns.HandleSlash("dev")
        assert.truthy(WowStub.printed[#WowStub.printed]:find("on (1 character(s) saved)", 1, true))
        ns.HandleSlash("dev off")
        assert.is_nil(LedgerLinkDB.dev)
        logout(ns)
        assert.is_nil(LedgerLinkDB.dev)
        ns.HandleSlash("dev")
        assert.truthy(WowStub.printed[#WowStub.printed]:find("Dev snapshot off", 1, true))
    end)

    it("Init never creates dev and repairs a bad type", function()
        LedgerLinkDB.dev = "garbage"
        ns.Init()
        assert.is_nil(LedgerLinkDB.dev)
        LedgerLinkDB.dev = { v = 1, snapshots = 5 }
        ns.Init()
        assert.same({}, LedgerLinkDB.dev.snapshots)
    end)

    it("reports name-bearing calls as presence only; no GUID, name, realm or guild anywhere", function()
        local st = WowStub.state
        st.getUnitName, st.unitName, st.unitFullName = "Zqxname Zqxrealm", { "Zqxname" }, { "Zqxname", "Zqxrealm" }
        st.realmName, st.guild = "Zqxrealm", "Zqxguild"
        st.guildRoster = { WowStub.member(0, { guid = GUID, name = "Zqxname-Zqxrealm" }) }
        ns.Probe.SECTION_BUILDERS.S9 = function(lines) lines[1] = "S9 leaked " .. GUID .. " here" end
        ns.HandleSlash("dev on")
        logout(ns)
        local json = stored()
        local snap = assertShape(ns, json)
        for _, needle in ipairs({ "Zqxname", "Zqxrealm", "Zqxguild", "0ABCDEF0", "OFFICER SECRET", "public note" }) do
            assert.is_nil(json:find(needle, 1, true), needle .. " leaked into the snapshot")
        end
        assert.equal("S9 leaked <guid> here", snap.sections[2].lines[1])
        local byFn = {}
        for _, item in ipairs(snap.calls) do byFn[item.fn] = item end
        for fn in pairs(ns.Probe.NAME_BEARING) do
            assert.equal("presence", byFn[fn].status, fn)
            assert.equal(type(_G[fn]), byFn[fn].type, fn)
            assert.is_nil(byFn[fn].values, fn)
        end
        assert.equal("ok", byFn.UnitClass.status)
        assert.same({ "Paladin", "PALADIN", 2 }, byFn.UnitClass.values)
        assert.equal("missing", byFn["C_GameRules.IsStandard"].status)
    end)

    it("iterates whatever Enum.GameRule holds and records IsGameRuleActive per member", function()
        WowStub.gameRules({ SyntheticRuleB = 7, SyntheticRuleA = 3 }, { SyntheticRuleA = true, SyntheticRuleB = false })
        local rs = ns.DevSnapshot.Build().ruleset
        assert.equal("function", rs.isGameRuleActive)
        assert.equal("table", rs.enumGameRule)
        assert.same({ { name = "SyntheticRuleA", value = 3, active = true },
            { name = "SyntheticRuleB", value = 7, active = false } }, rs.rules)
        WowStub.gameRules({ OtherRule = 1, Throws = 2 }, { OtherRule = 1, Throws = function() error("boom") end })
        rs = decode(ns.Json.encode(ns.DevSnapshot.Build())).ruleset
        assert.equal(dkjson.null, rs.rules[1].active) -- a non-boolean answer
        assert.equal("Throws", rs.rules[2].name)
        assert.truthy(rs.rules[2].error:find("boom", 1, true))
    end)

    it("a non-finite region or Enum.GameRule value still encodes (region null, rule value a string)", function()
        WowStub.state.region = math.huge
        WowStub.gameRules({ Inf = math.huge, NegInf = -math.huge }, { Inf = true, NegInf = false })
        local ok, json = pcall(function() return ns.Json.encode(ns.DevSnapshot.Build()) end)
        assert(ok, json)
        local snap = decode(json)
        assert.equal(dkjson.null, snap.client.region)
        assert.equal("string", type(snap.ruleset.rules[1].value))
        assert.equal("string", type(snap.ruleset.rules[2].value))
    end)

    it("IsGameRuleActive missing -> no rules, type recorded as nil", function()
        _G.Enum.GameRule = { SyntheticRuleA = 1 }
        local rs = ns.DevSnapshot.Build().ruleset
        assert.equal("nil", rs.isGameRuleActive)
        assert.equal("table", rs.enumGameRule)
        assert.equal(0, #rs.rules)
        assert.equal("[]", ns.Json.encode(rs.rules))
    end)

    it("a section that throws is status error; the others are still there", function()
        ns.Probe.SECTION_BUILDERS.S3 = function(lines) lines[1] = "S3 partial" error("kaput") end
        local snap = ns.DevSnapshot.Build()
        assert.equal("error", snap.sections[1].status)
        assert.truthy(snap.sections[1].error:find("kaput", 1, true))
        assert.equal("S3 partial", snap.sections[1].lines[1])
        assert.equal("ok", snap.sections[2].status)
    end)

    it("skips the remaining sections once the 50 ms guard is spent", function()
        WowStub.state.clockStepMs = 60
        local snap = ns.DevSnapshot.Build()
        assert.equal("skipped", snap.sections[1].status)
        assert.equal("skipped", snap.sections[2].status)
        assert.is_true(snap.truncated)
    end)

    it("the 50 ms guard counts the time spent before the sections (S1/S2 calls)", function()
        local clock, realStop, realBuildInfo = 0, _G.debugprofilestop, _G.GetBuildInfo
        _G.debugprofilestop = function() return clock end
        _G.GetBuildInfo = function(...) clock = clock + 60 return realBuildInfo(...) end
        local ok, snap = pcall(ns.DevSnapshot.Build)
        _G.debugprofilestop, _G.GetBuildInfo = realStop, realBuildInfo
        assert(ok, snap)
        assert.equal("skipped", snap.sections[1].status)
        assert.is_true(snap.truncated)
    end)

    it("cuts a 1,000-line section to fit 3 KiB and marks it truncated", function()
        ns.Probe.SECTION_BUILDERS.S9 = function(lines)
            for i = 1, 1000 do lines[i] = "S9 line " .. i .. " " .. string.rep("é", 200) end
        end
        ns.HandleSlash("dev on")
        logout(ns)
        local snap = assertShape(ns, stored())
        local s9 = snap.sections[2]
        assert.is_true(s9.truncated)
        assert.is_true(#s9.lines > 0 and #s9.lines <= 40)
        -- assertShape returns the dkjson value: re-mark its arrays before measuring with the addon's encoder
        assert.is_true(#ns.Json.encode(addonValue(ns.Json, s9)) <= 3072)
        assert.is_true(snap.truncated)
    end)

    it("a worst-case snapshot (every section, call and rule over its cap) encodes within 48 KiB", function()
        -- A control byte encodes as \u0001 (six bytes per input byte); short values pack every item to ~3 KiB.
        local value, line = string.rep("\1", 70), string.rep("\1", 40)
        for id in pairs(ns.Probe.SECTION_BUILDERS) do
            ns.Probe.SECTION_BUILDERS[id] = function(lines) for i = 1, 1000 do lines[i] = line end end
        end
        local saved = {}
        for _, spec in ipairs(ns.Probe.CALLS) do
            local owner, key = _G, spec[1]
            local head, tail = spec[1]:match("^([%w_]+)%.([%w_]+)$")
            if head then owner, key = _G[head], tail end
            if type(owner) == "table" then
                saved[#saved + 1] = { owner, key, owner[key] }
                owner[key] = function()
                    local out = {}
                    for i = 1, 60 do out[i] = value end
                    return unpack(out)
                end
            end
        end
        local members, active = {}, {}
        for i = 1, 100 do
            local name = "Rule" .. string.rep("X", 56) .. string.format("%04d", i)
            members[name], active[name] = i, i % 2 == 0
        end
        WowStub.gameRules(members, active)
        local ok, built = pcall(ns.DevSnapshot.Build)
        for i = #saved, 1, -1 do saved[i][1][saved[i][2]] = saved[i][3] end
        assert(ok, built)
        local json = ns.Json.encode(built)
        assert.is_true(#json <= ns.DevSnapshot.MAX_BYTES, "worst-case snapshot is " .. #json .. " bytes")
        assert.is_true(built.truncated)
        assertShape(ns, json)
        assertPinnedSchema(json, "the worst-case snapshot")
    end)

    it("measures bytes like devBridgeJsonBytes (raw UTF-8, short escapes, \\u00XX controls)", function()
        -- node: JSON.stringify('é"\n\u0001') counted as UTF-8 = 14 bytes
        assert.equal('"é\\"\\n\\u0001"', ns.Json.encode('é"\n\1'))
        assert.equal(14, #ns.Json.encode('é"\n\1'))
    end)

    it("keeps at most 10 characters, dropping the oldest, never the current one", function()
        ns.HandleSlash("dev on")
        for i = 1, 10 do
            local guid = string.format("Player-4395-%08X", 0x30000 + i)
            LedgerLinkDB.dev.snapshots[guid], LedgerLinkDB.dev.capturedAt[guid] = "{}", i
        end
        logout(ns)
        assert.equal(10, count(LedgerLinkDB.dev.snapshots))
        assert.is_string(stored())
        assert.is_nil(LedgerLinkDB.dev.snapshots["Player-4395-00030001"])
        assert.is_string(LedgerLinkDB.dev.snapshots["Player-4395-00030002"])
    end)

    it("a build failure never throws and keeps the previous snapshot", function()
        ns.HandleSlash("dev on")
        logout(ns)
        local before = stored()
        ns.DevSnapshot.Build = function() error("builder broke") end
        assert.has_no.errors(function() logout(ns) end)
        assert.is_false(ns.DevSnapshot.OnLogout())
        assert.equal(before, stored())
    end)

    it("stores nothing without a valid player GUID", function()
        ns.HandleSlash("dev on")
        WowStub.state.guid = "not-a-guid"
        logout(ns)
        assert.equal(0, count(LedgerLinkDB.dev.snapshots))
    end)

    it("/rl probe still prints S3 then S4 (S3 no longer chains S4)", function()
        _G.date = function() return "2026-11-03 00:00" end
        local expected = {}
        ns.Probe.SECTION_BUILDERS.S3(expected)
        local s3Count = #expected
        ns.Probe.SECTION_BUILDERS.S4(expected)
        assert.is_true(s3Count > 0 and #expected > s3Count)
        local report = ns.Probe.Report()
        _G.date = os.date
        assert.truthy(report:find(table.concat(expected, "\n"), 1, true))
    end)

    it("watches every API the stub defines (WATCHED + PRESENCE + CALLS)", function()
        local listed = {}
        for _, list in ipairs({ ns.DevSnapshot.WATCHED, ns.Probe.PRESENCE }) do
            for _, path in ipairs(list) do listed[path] = true end
        end
        for _, spec in ipairs(ns.Probe.CALLS) do listed[spec[1]] = true end
        assert.is_true(#ns.DevSnapshot.Build().apis <= 160)
        local harness = set({ "WowStub", "unpack", "time", "date", "print", "CreateFrame", "UIParent", "Minimap",
            "GameTooltip", "UISpecialFrames", "ChatFontNormal", "SlashCmdList", "LedgerLinkDB", "LedgerLinkCharDB" })
        local missing = {}
        for name in io.open("spec/support/wow_stub.lua"):read("*a"):gmatch("\n_G%.([%w_]+)%s*=") do
            if not harness[name] then
                if not listed[name] then missing[#missing + 1] = name end
                if type(_G[name]) == "table" then
                    for member, v in pairs(_G[name]) do
                        local path = name .. "." .. member
                        if (type(v) == "function" or name == "Enum") and not listed[path] then
                            missing[#missing + 1] = path
                        end
                    end
                end
            end
        end
        table.sort(missing)
        assert.same({}, missing)
    end)
end)
