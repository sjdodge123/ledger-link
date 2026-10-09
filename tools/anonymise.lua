-- Anonymise a real export paste (one or more pages) before it becomes a
-- fixture: player names (and their first/surname parts), GUIDs (server id kept),
-- guild name, public notes and raid roster names are replaced consistently
-- across pages; realms, bosses, items and numbers are kept. The JSON is edited
-- textually (key order and number formatting stay exactly as the addon wrote
-- them), then re-compressed and re-encoded with the original page headers.
-- Fails if any original personal string survives.
-- Usage: luajit tools/anonymise.lua <real.txt> <out.txt>
package.path = "./?.lua;" .. package.path
local LibDeflate = require("LibDeflate")
local base64 = require("spec.support.base64")
local decode = require("spec.support.decode")

local input, output = assert(arg[1], "usage: anonymise.lua <real.txt> <out.txt>"), assert(arg[2])
local f = assert(io.open(input))
local paste = f:read("*a")
f:close()

local map, originals, counters = {}, {}, { part = 0, guid = 0, note = 0 }

local function remember(orig, new)
    if type(orig) ~= "string" or orig == "" then return end
    if not map[orig] then
        map[orig] = new
        originals[#originals + 1] = orig
    end
end

local function anonPart(part)
    if not map[part] then
        counters.part = counters.part + 1
        remember(part, (counters.part % 2 == 1 and "Anon" or "Surname") .. counters.part)
    end
    return map[part]
end

-- "First Surname" or "First Surname-Realm" -> each part mapped on its own.
local function anonName(full)
    if type(full) ~= "string" or full == "" then return end
    local name, realm = full:match("^(.-)%-(.+)$")
    name = name or full
    local parts = {}
    for p in name:gmatch("%S+") do parts[#parts + 1] = anonPart(p) end
    local new = table.concat(parts, " ")
    remember(name, new)
    if realm then remember(full, new .. "-" .. realm) end
end

local function anonGuid(guid)
    if type(guid) ~= "string" or map[guid] then return end
    local server = guid:match("^Player%-(%d+)%-%x+$")
    if not server then return end
    counters.guid = counters.guid + 1
    remember(guid, string.format("Player-%s-%08X", server, 0xA0000 + counters.guid))
end

local pages = {}
for token in paste:gmatch("%S+") do pages[#pages + 1] = { token = token, d = decode(token) } end
assert(#pages > 0, "no export string in " .. input)

for _, page in ipairs(pages) do
    local p = page.d.payload
    local who = p.who
    anonGuid(who.guid)
    anonName(who.fullName)
    anonName(who.raw.getUnitName)
    for _, key in ipairs({ "unitName", "unitFullName" }) do
        for _, part in ipairs(type(who.raw[key]) == "table" and who.raw[key] or {}) do
            if type(part) == "string" then anonPart(part) end
        end
    end
    remember(who.guildName, "Anon Guild")
    if p.section == "guild" then
        remember(p.data.name, "Anon Guild")
        for _, m in ipairs(p.data.members) do
            anonGuid(m.guid)
            anonName(m.name)
            if m.note and m.note ~= "" and not map[m.note] then
                counters.note = counters.note + 1
                remember(m.note, "note " .. counters.note)
            end
        end
    elseif p.section == "raid" then
        for _, pull in ipairs(p.data.pulls) do
            for _, g in ipairs(pull.roster or {}) do anonGuid(g) end
            for _, n in ipairs(type(pull.rosterNames) == "table" and pull.rosterNames or {}) do anonName(n) end
        end
    end
end

-- Longest first, so "First Surname" is replaced before "First".
table.sort(originals, function(a, b) return #a > #b end)

local function escapePattern(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

-- Every string VALUE in the anonymised JSON (keys excluded), checked whole and
-- word by word (split on spaces and "-"), so "First Surname-Realm" can't hide a
-- surviving part; realm fields (public) are checked whole only. Reports where,
-- never the personal string itself.
local isOriginal = {}
for _, orig in ipairs(originals) do isOriginal[orig] = true end
local function assertNoLeak(json, page)
    local function check(v, path)
        if type(v) == "table" then
            for k, child in pairs(v) do check(child, path .. "." .. tostring(k)) end
        elseif type(v) == "string" then
            local leak = isOriginal[v]
            -- Realm names are public and kept on purpose; a member whose name
            -- shares a word with the realm ("Beta") must not block them.
            local realm = path:match("%.realmName$") or path:match("%.rawRealm$")
            if not realm then
                for word in v:gmatch("[^%s%-]+") do leak = leak or isOriginal[word] end
            end
            if leak then error(string.format("a personal string survived in page %d at %s", page, path), 0) end
        end
    end
    check(require("dkjson").decode(json), "")
end

local out = {}
for i, page in ipairs(pages) do
    local json = page.d.json
    for _, orig in ipairs(originals) do
        json = json:gsub('"' .. escapePattern(orig) .. '"', '"' .. map[orig]:gsub("%%", "%%%%") .. '"')
    end
    assertNoLeak(json, i)
    local header = page.token:match("^(!RL%d+![^!]+!)")
    local body = base64.encode(LibDeflate:CompressZlib(json))
    out[i] = header .. body
    assert(decode(out[i]).json == json, "round trip failed")
end

f = assert(io.open(output, "w"))
f:write(table.concat(out, "\n"))
f:close()
print(string.format("%s: %d page(s), %d personal strings replaced", output, #out, #originals))
