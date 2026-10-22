-- /rl probe "S9" lines (Raid Ledger ROK-1907, 2026-10-22): can an addon read
-- professions on Forever? GetProfessions + GetProfessionInfo,
-- C_TradeSkillUI.GetProfessionInfoBySkillLineID and C_SkillInfo are each
-- reported, then a verdict per source. Read-only: no header is expanded.
local loadAddon = require("spec.support.load_addon")

local function report(ns)
    ns.HandleSlash("probe")
    return ns.ExportFrame.GetText()
end

local function has(text, needle)
    assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
end

local function hasnt(text, needle)
    assert.falsy(text:find(needle, 1, true), "unexpected: " .. needle .. "\n---\n" .. text)
end

local STUBBED = { "GetProfessions", "GetProfessionInfo", "C_TradeSkillUI", "C_SkillInfo" }

local PROFESSIONS = {
    [3] = { "Mining", "icon", 75, 150, 2, 0, 186, 0 },
    [7] = { "Cooking", "icon", 1, 75, 1, 2, 185, 0 },
}

local SKILL_LINES = {
    { skillID = 0, name = "Professions", isHeader = true, isCollapsed = false },
    { skillID = 186, name = "Mining", isHeader = false, rank = 75, maxRank = 150, skillLineCategoryID = 11,
        parentSkillLineID = 0 },
    { skillID = 0, name = "Secondary Skills", isHeader = true, isCollapsed = false },
    { skillID = 185, name = "Cooking", isHeader = false, rank = 1, maxRank = 75, skillLineCategoryID = 9,
        parentSkillLineID = 0 },
    { skillID = 0, name = "Weapon Skills", isHeader = true, isCollapsed = true },
    { skillID = 44, name = "Axes", isHeader = false, rank = 40, maxRank = 50, skillLineCategoryID = 6,
        parentSkillLineID = 0 },
}

describe("/rl probe: S9 professions", function()
    local ns, saved, expanded
    before_each(function()
        saved = {}
        for _, name in ipairs(STUBBED) do saved[name] = rawget(_G, name) end
        ns = loadAddon()
        expanded = 0
        _G.GetProfessions = function() return 3, nil, nil, nil, 7 end
        _G.GetProfessionInfo = function(index) return unpack(PROFESSIONS[index]) end
        _G.C_TradeSkillUI = {
            GetProfessionInfoBySkillLineID = function(skillLine)
                if skillLine == 186 then
                    return { professionName = "Mining", skillLevel = 75, maxSkillLevel = 150 }
                end
                return { professionName = "", skillLevel = 0, maxSkillLevel = 0 }
            end,
        }
        _G.C_SkillInfo = {
            GetNumSkillLines = function() return #SKILL_LINES end,
            GetSkillLineInfo = function(index) return SKILL_LINES[index] end,
            ExpandSkillHeader = function() expanded = expanded + 1 end,
        }
    end)
    after_each(function()
        for _, name in ipairs(STUBBED) do _G[name] = saved[name] end
    end)

    it("reports each source and a verdict per source that returned professions", function()
        local text = report(ns)
        has(text, "S9 GetProfessions() = prof1=3 prof2=nil firstAid=nil fishing=nil cooking=7")
        has(text, 'S9 GetProfessionInfo(3) [prof1] name="Mining" skill=75 max=150 skillLine=186 modifier=0')
        has(text, 'S9 GetProfessionInfo(7) [cooking] name="Cooking" skill=1 max=75 skillLine=185 modifier=0')
        has(text, 'S9 C_TradeSkillUI.GetProfessionInfoBySkillLineID(186) = {maxSkillLevel = 150, '
            .. 'professionName = "Mining", skillLevel = 75}')
        has(text, 'S9 skill line 2 "Mining" skillID=186 rank=75 max=150 category=11 parent=0 <- profession')
        has(text, 'S9 skill line 6 "Axes" skillID=44 rank=40 max=50 category=6 parent=0')
        hasnt(text, '"Axes" skillID=44 rank=40 max=50 category=6 parent=0 <- profession')
        has(text, 'S9 skill header 5 "Weapon Skills" (collapsed: expand it on the Skills tab and probe again)')
        has(text, "S9 verdict: YES via GetProfessions + GetProfessionInfo: Mining 75/150, Cooking 1/75")
        -- Cooking's 0/0 from C_TradeSkillUI is "not loaded", not a profession.
        has(text, "S9 verdict: YES via C_TradeSkillUI.GetProfessionInfoBySkillLineID: Mining 75/150\n")
        has(text, "S9 verdict: YES via C_SkillInfo.GetSkillLineInfo: Mining 75/150, Cooking 1/75")
        assert.equal(0, expanded, "the probe never expands a skill header")
    end)

    it("says NO when no source returns a profession", function()
        _G.GetProfessions = function() return nil, nil, nil, nil, nil end
        _G.C_SkillInfo.GetNumSkillLines = function() return 0 end
        local text = report(ns)
        has(text, "S9 GetProfessions() = prof1=nil prof2=nil firstAid=nil fishing=nil cooking=nil")
        has(text, "S9 C_SkillInfo.GetNumSkillLines() = 0")
        has(text, "S9 verdict: NO, no source returned a profession")
        hasnt(text, "S9 verdict: YES")
    end)

    it("reports missing functions and errors instead of failing", function()
        _G.GetProfessions = nil
        _G.C_SkillInfo.GetSkillLineInfo = function() error("blocked") end
        local text = report(ns)
        has(text, "S9 GetProfessions() = missing")
        has(text, "S9 skill line 1 = error: ")
        has(text, "blocked")
        has(text, "S9 verdict: NO")
    end)
end)
