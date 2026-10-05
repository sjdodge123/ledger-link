-- Load the addon the way the client does: every file listed in the .toc,
-- in order, each called with (addonName, namespace).
require("spec.support.wow_stub")

local ROOT = "LedgerLink/"

local function tocFiles()
    local files = {}
    for line in io.lines(ROOT .. "LedgerLink.toc") do
        if line ~= "" and not line:match("^##") then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    return files
end

return function()
    WowStub.reset()
    local ns = {}
    for _, file in ipairs(tocFiles()) do
        local chunk = assert(loadfile(ROOT .. file))
        chunk("LedgerLink", ns)
    end
    ns.Init()
    return ns
end
