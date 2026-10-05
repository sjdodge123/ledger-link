-- Beta 2026-10-05, playing with a gamepad: /rl export guild raised
-- "LedgerLink has been blocked from an action only available to the Blizzard
-- UI", naming SetPreferredGamepadInteractTarget(), and any click afterwards
-- crashed the client. The addon moved keyboard focus itself
-- (editBox:SetFocus()) while the game was still handling the chat command;
-- the gamepad UI reacted inside that addon-started call chain. So the addon
-- never moves focus: the player clicks the text (the game moves focus), which
-- selects all of it.
local loadAddon = require("spec.support.load_addon")

describe("export window focus", function()
    local ns
    before_each(function()
        ns = loadAddon()
        WowStub.focusCalls = 0
    end)

    it("never calls SetFocus when an export or the probe opens, or on page changes", function()
        ns.HandleSlash("export char")
        WowStub.state.guildRoster = WowStub.roster(600)
        ns.HandleSlash("export guild")
        ns.ExportFrame.NextPage()
        ns.ExportFrame.PrevPage()
        ns.HandleSlash("probe")
        assert.equal(0, WowStub.focusCalls)
    end)

    it("selects all text when the player clicks it (focus moved by the game, not the addon)", function()
        ns.HandleSlash("export char")
        local box = WowStub.frames.LedgerLinkExportEditBox
        local highlighted = 0
        rawset(box, "HighlightText", function() highlighted = highlighted + 1 end)
        box.scripts.OnEditFocusGained(box)
        box.scripts.OnMouseUp(box)
        assert.equal(2, highlighted)
        assert.equal(0, WowStub.focusCalls)
    end)

    it("tells the player to click the text before Ctrl+C", function()
        ns.HandleSlash("export char")
        assert.truthy(ns.ExportFrame.GetFooter():find("Click the text", 1, true))
        ns.HandleSlash("probe")
        assert.truthy(ns.ExportFrame.GetFooter():find("Click the text", 1, true))
    end)
end)
