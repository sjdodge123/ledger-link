-- Generate addon export strings (char, guild incl. multi-page, raid) with the
-- WoW stub, one file per case, for tools/verify-with-raid-ledger.sh. A paged
-- guild case is written as ONE paste (pages joined by newlines), plus a
-- `-reversed` copy with the pages in reverse order.
-- Usage: luajit tools/gen_strings.lua <outdir>
package.path = "./?.lua;" .. package.path
local exportCases = require("spec.support.export_cases")
local outDir = assert(arg[1], "usage: gen_strings.lua <outdir>")

local function write(name, text)
    local f = assert(io.open(outDir .. "/" .. name .. ".txt", "w"))
    f:write(text)
    f:close()
end

for _, case in ipairs(exportCases.cases) do
    local pages = exportCases.run(case)
    write(case.name, table.concat(pages, "\n"))
    if case.reversed then
        local rev = {}
        for i = #pages, 1, -1 do rev[#rev + 1] = pages[i] end
        write(case.name .. "-reversed", table.concat(rev, "\n"))
    end
    local bytes = 0
    for _, p in ipairs(pages) do bytes = bytes + #p end
    print(string.format("%s %d page(s) %d bytes", case.name, #pages, bytes))
end
