-- In-game UI: the /rl panel, the minimap button and the addon-list icon.
local loadAddon = require("spec.support.load_addon")

local function click(name, button)
    local w = assert(WowStub.frames[name], "no frame named " .. name)
    w.scripts.OnClick(w, button or "LeftButton")
end

local function printedContains(text)
    for _, line in ipairs(WowStub.printed) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

describe("/rl", function()
    it("opens the panel with no arguments, and toggles it", function()
        local ns = loadAddon()
        ns.HandleSlash("")
        assert.is_true(ns.Panel.IsShown())
        ns.HandleSlash("")
        assert.is_false(ns.Panel.IsShown())
    end)

    it("prints the command list on /rl help", function()
        local ns = loadAddon()
        ns.HandleSlash("help")
        assert.is_true(printedContains("/rl export char"))
        assert.is_false(ns.Panel.IsShown())
    end)
end)

describe("panel", function()
    local ns
    before_each(function()
        ns = loadAddon()
        ns.Panel.Show()
    end)

    -- Operator 2026-10-09: one export button in the panel (the "Export all"
    -- paste); the per-section exports stay as optional slash commands.
    it("has a single export button that makes the one-paste export", function()
        WowStub.raid(5)
        ns.Raid.OnEvent("ENCOUNTER_START", 663, "Lucifron", 9, 40)
        ns.Raid.OnEvent("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
        click("LedgerLinkPanelExport")
        assert.is_true(WowStub.frames.LedgerLinkExportFrame.shown)
        local lines = {}
        for line in ns.ExportFrame.GetText():gmatch("[^\n]+") do lines[#lines + 1] = line:match("^!RL1!(%a+)") end
        assert.same({ "char", "guild", "raid" }, lines)
        for _, gone in ipairs({ "LedgerLinkPanelExportChar", "LedgerLinkPanelExportGuild",
            "LedgerLinkPanelExportRaid", "LedgerLinkPanelExportAll" }) do
            assert.is_nil(WowStub.frames[gone], gone .. " should not exist")
        end
    end)

    it("leaves the per-section exports to slash commands", function()
        ns.HandleSlash("export char")
        assert.truthy(ns.ExportFrame.GetText():match("^!RL1!char!"))
    end)

    it("sets the ruleset and highlights the chosen one", function()
        click("LedgerLinkPanelRulesetroleplaying")
        assert.equal("roleplaying", LedgerLinkCharDB.ruleset)
        assert.is_true(WowStub.frames.LedgerLinkPanelRulesetroleplaying.highlighted)
        assert.is_false(WowStub.frames.LedgerLinkPanelRulesetnormal.highlighted)
        click("LedgerLinkPanelRulesethardcore")
        assert.equal("hardcore", LedgerLinkCharDB.ruleset)
        assert.is_false(WowStub.frames.LedgerLinkPanelRulesetroleplaying.highlighted)
    end)

    it("reflects a ruleset set by slash command", function()
        ns.HandleSlash("ruleset pvp")
        assert.is_true(WowStub.frames.LedgerLinkPanelRulesetpvp.highlighted)
    end)

    it("toggles public guild notes (officer notes are never offered)", function()
        local box = WowStub.frames.LedgerLinkPanelGuildNotes
        assert.is_false(box.checked)
        box.checked = true
        click("LedgerLinkPanelGuildNotes")
        assert.is_true(LedgerLinkDB.guildNotes)
        box.checked = false
        click("LedgerLinkPanelGuildNotes")
        assert.is_false(LedgerLinkDB.guildNotes)
    end)

    it("shows the recorded pull count and clears it", function()
        WowStub.raid(5)
        ns.Raid.OnEvent("ENCOUNTER_START", 663, "Lucifron", 9, 40)
        ns.Raid.OnEvent("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
        ns.Panel.Refresh()
        assert.truthy(ns.Panel.GetPullsText():find("1", 1, true))
        click("LedgerLinkPanelClearPulls")
        assert.equal(0, #ns.Raid.Pulls())
        assert.truthy(ns.Panel.GetPullsText():find("0", 1, true))
    end)

    it("shows the region picker only when the game doesn't report a region (beta)", function()
        assert.is_false(WowStub.frames.LedgerLinkPanelRegionus.shown)
        WowStub.state.region = 90
        ns.Panel.Refresh()
        assert.is_true(WowStub.frames.LedgerLinkPanelRegionus.shown)
        click("LedgerLinkPanelRegioneu")
        assert.equal("eu", LedgerLinkDB.region)
        assert.is_true(WowStub.frames.LedgerLinkPanelRegioneu.highlighted)
        assert.is_false(WowStub.frames.LedgerLinkPanelRegionus.highlighted)
    end)

    it("opens the beta probe", function()
        click("LedgerLinkPanelProbe")
        assert.truthy(ns.ExportFrame.GetText():find("probe at", 1, true))
    end)

    it("never moves keyboard focus from any control (gamepad blocked-action crash)", function()
        WowStub.focusCalls = 0
        WowStub.raid(5)
        ns.Raid.OnEvent("ENCOUNTER_START", 663, "Lucifron", 9, 40)
        ns.Raid.OnEvent("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
        for _, name in ipairs({ "LedgerLinkPanelExport",
            "LedgerLinkPanelRulesetpvp", "LedgerLinkPanelRegionus", "LedgerLinkPanelGuildNotes",
            "LedgerLinkPanelClearPulls", "LedgerLinkPanelProbe" }) do
            click(name)
        end
        click("LedgerLinkMinimapButton")
        click("LedgerLinkMinimapButton")
        assert.equal(0, WowStub.focusCalls)
    end)

    -- Beta feedback 2026-10-05: the export window opened on top of the panel,
    -- and with the translucent dialog background the two were hard to tell
    -- apart. The panel steps aside, and both windows are near-opaque.
    it("closes when it opens an export or the probe, so only one window is up", function()
        click("LedgerLinkPanelExport")
        assert.is_false(ns.Panel.IsShown())
        assert.is_true(WowStub.frames.LedgerLinkExportFrame.shown)
        ns.Panel.Show()
        click("LedgerLinkPanelProbe")
        assert.is_false(ns.Panel.IsShown())
    end)

    it("stays open when an export can't run, so the player sees why", function()
        WowStub.state.inCombat = true
        click("LedgerLinkPanelExport")
        assert.is_true(ns.Panel.IsShown())
    end)

    it("panel and export window have a near-opaque background", function()
        click("LedgerLinkPanelExport")
        for _, name in ipairs({ "LedgerLinkPanel", "LedgerLinkExportFrame" }) do
            local color = WowStub.frames[name].backdropColor
            assert(color, name .. " has no backdrop colour")
            assert.truthy(color[4] >= 0.9, name .. " background alpha " .. tostring(color[4]))
        end
    end)

    it("closes with Escape", function()
        local found = false
        for _, name in ipairs(UISpecialFrames) do found = found or name == "LedgerLinkPanel" end
        assert.is_true(found)
    end)
end)

describe("minimap button", function()
    it("is created on load with the addon icon and toggles the panel on click", function()
        local ns = loadAddon()
        local b = assert(WowStub.frames.LedgerLinkMinimapButton)
        assert.is_true(b.shown)
        assert.equal("Interface\\AddOns\\LedgerLink\\Textures\\Minimap", ns.Minimap.ICON)
        click("LedgerLinkMinimapButton")
        assert.is_true(ns.Panel.IsShown())
        click("LedgerLinkMinimapButton")
        assert.is_false(ns.Panel.IsShown())
    end)

    it("shows status in its tooltip", function()
        loadAddon()
        local b = WowStub.frames.LedgerLinkMinimapButton
        b.scripts.OnEnter(b)
        local text = table.concat(GameTooltip.lines, "\n")
        assert.truthy(text:find("Ledger Link", 1, true))
        assert.truthy(text:find("Ruleset", 1, true))
    end)

    it("saves its position around the minimap after a drag", function()
        local ns = loadAddon()
        local b = WowStub.frames.LedgerLinkMinimapButton
        WowStub.state.cursor = { 1000, 600 } -- straight above the minimap centre
        b.scripts.OnDragStart(b)
        b.scripts.OnUpdate(b)
        b.scripts.OnDragStop(b)
        assert.near(90, LedgerLinkDB.minimap.angle, 0.001)
        assert.equal("CENTER", b.point[1])
        assert.near(0, b.point[4], 0.001)
        assert.truthy(b.point[5] > 0)
        assert.is_nil(b.scripts.OnUpdate)
        WowStub.state.cursor = { 900, 500 } -- left
        b.scripts.OnDragStart(b)
        b.scripts.OnUpdate(b)
        b.scripts.OnDragStop(b)
        assert.near(180, LedgerLinkDB.minimap.angle, 0.001)
        assert.is_true(ns.Minimap ~= nil)
    end)

    it("explains /rl minimap usage", function()
        local ns = loadAddon()
        ns.HandleSlash("minimap sideways")
        assert.is_true(printedContains("/rl minimap on|off"))
    end)

    it("hides with /rl minimap off, remembers it, and comes back with on", function()
        local ns = loadAddon()
        ns.HandleSlash("minimap off")
        assert.is_false(WowStub.frames.LedgerLinkMinimapButton.shown)
        assert.is_true(LedgerLinkDB.minimap.hide)
        -- next session: SavedVariables persist, the button stays hidden
        local saved = LedgerLinkDB
        ns = loadAddon()
        _G.LedgerLinkDB = saved
        ns.Init()
        assert.is_false(WowStub.frames.LedgerLinkMinimapButton.shown)
        ns.HandleSlash("minimap on")
        assert.is_true(WowStub.frames.LedgerLinkMinimapButton.shown)
        assert.is_false(LedgerLinkDB.minimap.hide)
    end)
end)

describe("minimap texture", function()
    it("ns.Minimap.ICON is an uncompressed 32-bit TGA shipped in the addon folder", function()
        local ns = loadAddon()
        local file = ns.Minimap.ICON:gsub("^Interface\\AddOns\\", ""):gsub("\\", "/") .. ".tga"
        local f = assert(io.open(file, "rb"), "missing " .. file)
        local header = f:read(18)
        f:close()
        assert.equal(2, header:byte(3))
        assert.equal(32, header:byte(17))
    end)
end)

describe("addon list icon", function()
    it("points ## IconTexture at a texture shipped in the addon folder", function()
        local toc = io.open("LedgerLink/LedgerLink.toc"):read("*a")
        local path = assert(toc:match("## IconTexture: (%S+)"), "no ## IconTexture")
        local file = path:gsub("^Interface\\AddOns\\", ""):gsub("\\", "/") .. ".tga"
        local f = assert(io.open(file, "rb"), "missing " .. file)
        local header = f:read(18)
        f:close()
        assert.equal(2, header:byte(3), "TGA must be uncompressed (type 2)")
        assert.equal(32, header:byte(17), "TGA must be 32-bit (alpha)")
    end)
end)
