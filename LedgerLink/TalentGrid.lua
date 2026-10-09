-- WoW: Forever talent layout (probes 2026-10-09: Warrior, Druid, Paladin): one
-- C_Traits tree per class holding three vanilla-style sub-trees side by side,
-- each 4 columns x 7 rows, 600 apart, rows from posY 2130. Positions can be off
-- by ~10 (Paladin posX 5020 and 5030 share a column), so everything rounds:
--   tree = posX cluster (a gap over 2000 starts the next sub-tree), 0-2. Inside
--          a sub-tree the widest possible gap is 1800 (columns 1 and 2 empty);
--          between sub-trees it is about 2200.
--   col  = round((posX - cluster min) / 600)
--   row  = round((posY - 2130) / 600)
-- Shared by /rl probe and the char export (Raid Ledger ROK-1744).
local _, ns = ...

local TalentGrid = {}
ns.TalentGrid = TalentGrid

TalentGrid.STEP = 600
TalentGrid.ROW_ORIGIN = 2130
TalentGrid.GROUP_GAP = 2000

local function round(x) return math.floor(x + 0.5) end

--- Adds tree / row / col to every node that has numeric posX and posY.
function TalentGrid.Assign(nodes)
    local xs = {}
    for _, n in ipairs(nodes) do
        if type(n.posX) == "number" and type(n.posY) == "number" then xs[#xs + 1] = n.posX end
    end
    table.sort(xs)
    -- Cluster sorted posX values: a jump of more than GROUP_GAP starts a new sub-tree.
    local starts = {}
    for i, x in ipairs(xs) do
        if i == 1 or x - xs[i - 1] > TalentGrid.GROUP_GAP then starts[#starts + 1] = x end
    end
    for _, n in ipairs(nodes) do
        if type(n.posX) == "number" and type(n.posY) == "number" then
            local tree = 0
            for k = #starts, 1, -1 do
                if n.posX >= starts[k] then
                    tree = k - 1
                    break
                end
            end
            n.tree = tree
            n.col = round((n.posX - starts[tree + 1]) / TalentGrid.STEP)
            n.row = round((n.posY - TalentGrid.ROW_ORIGIN) / TalentGrid.STEP)
        end
    end
    return nodes
end
