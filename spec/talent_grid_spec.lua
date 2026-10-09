-- WoW: Forever talent trees (probes 2026-10-09, Warrior / Druid / Paladin): one
-- C_Traits tree per class holding three vanilla-style sub-trees side by side,
-- each 4 columns x 7 rows, 600 apart. tree = posX cluster (gaps ~2200), col =
-- round((posX - cluster min) / 600), row = round((posY - 2130) / 600).
-- Positions can be off by ~10 (Paladin posX 5020 and 5030 share a column).
local loadAddon = require("spec.support.load_addon")

local function nodes(xs, ys)
    local out = {}
    for i = 1, #xs do out[i] = { nodeId = 1000 + i, posX = xs[i], posY = ys[i] } end
    return out
end

describe("TalentGrid", function()
    local grid
    before_each(function() grid = loadAddon().TalentGrid end)

    it("maps the Warrior grid: three groups of four columns, seven rows", function()
        local n = nodes({ 1020, 2820, 5020, 6820, 9080, 10880 }, { 2130, 5730, 2130, 4530, 2730, 5730 })
        grid.Assign(n)
        assert.same({ 0, 0, 1, 1, 2, 2 }, { n[1].tree, n[2].tree, n[3].tree, n[4].tree, n[5].tree, n[6].tree })
        assert.same({ 0, 3, 0, 3, 0, 3 }, { n[1].col, n[2].col, n[3].col, n[4].col, n[5].col, n[6].col })
        assert.same({ 0, 6, 0, 4, 1, 6 }, { n[1].row, n[2].row, n[3].row, n[4].row, n[5].row, n[6].row })
    end)

    it("keeps a sub-tree together when its middle columns are empty (gap 1800 < 2000)", function()
        local n = nodes({ 1020, 2820, 5020 }, { 2130, 2130, 2130 })
        grid.Assign(n)
        assert.same({ 0, 0, 1 }, { n[1].tree, n[2].tree, n[3].tree })
        assert.same({ 0, 3, 0 }, { n[1].col, n[2].col, n[3].col })
    end)

    it("rounds positions that are off by a few units (Paladin 5020 / 5030)", function()
        local n = nodes({ 1020, 5020, 5030, 5620, 9080 }, { 2130, 2140, 2730, 3330, 5725 })
        grid.Assign(n)
        assert.same({ 0, 1, 1, 1, 2 }, { n[1].tree, n[2].tree, n[3].tree, n[4].tree, n[5].tree })
        assert.same({ 0, 0, 0, 1, 0 }, { n[1].col, n[2].col, n[3].col, n[4].col, n[5].col })
        assert.same({ 0, 0, 1, 2, 6 }, { n[1].row, n[2].row, n[3].row, n[4].row, n[5].row })
    end)

    it("leaves nodes without positions unassigned and never errors", function()
        local n = { { nodeId = 1 }, { nodeId = 2, posX = 1020, posY = 2130 } }
        grid.Assign(n)
        assert.is_nil(n[1].tree)
        assert.same({ 0, 0, 0 }, { n[2].tree, n[2].row, n[2].col })
        grid.Assign({})
    end)
end)
