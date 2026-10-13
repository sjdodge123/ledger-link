-- /rl probe "S8" lines (operator 2026-10-13): auction house deposits for each
-- tradeable bag stack, 12h / 24h / 48h, whole stack and one unit, via
-- C_AuctionHouse.CalculateItemDeposit / CalculateCommodityDeposit. Run at the
-- auction house. Calculations only: nothing is posted.
local loadAddon = require("spec.support.load_addon")

local function report(ns)
    ns.HandleSlash("probe")
    return ns.ExportFrame.GetText()
end

local function has(text, needle)
    assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
end

local STUBBED = { "AuctionHouseFrame", "C_AuctionHouse", "C_Container", "ItemLocation", "GetItemInfo", "NUM_BAG_SLOTS" }

local ORE = "|cffffffff|Hitem:2770::::::::8:::::|h[Copper Ore]|h|r"
local POLE = "|cffffffff|Hitem:6256::::::::8:::::|h[Fishing Pole]|h|r"
local STONE = "|cffffffff|Hitem:6948::::::::8:::::|h[Hearthstone]|h|r"
local CANDLE = "|cffffffff|Hitem:772::::::::8:::::|h[Large Candle]|h|r"

describe("/rl probe: S8 auction house deposits", function()
    local ns, saved, posted
    before_each(function()
        saved = {}
        for _, name in ipairs(STUBBED) do saved[name] = rawget(_G, name) end
        ns = loadAddon()
        posted = 0
        _G.NUM_BAG_SLOTS = 0
        local bag = {
            { itemID = 2770, hyperlink = ORE, stackCount = 5, isBound = false },
            { itemID = 6256, hyperlink = POLE, stackCount = 1, isBound = false },
            { itemID = 6948, hyperlink = STONE, stackCount = 1, isBound = true },
            { itemID = 772, hyperlink = CANDLE, stackCount = 7, isBound = false },
        }
        _G.C_Container = {
            GetContainerNumSlots = function() return #bag end,
            GetContainerItemInfo = function(_, slot) return bag[slot] end,
            GetContainerItemQuestInfo = function(_, slot) return { isQuestItem = slot == 4 } end,
        }
        _G.ItemLocation = { CreateFromBagAndSlot = function(_, b, sl) return { bag = b, slot = sl } end }
        _G.GetItemInfo = function(link) return "x", link, 1, 1, 1, "t", "s", 20, "", 0, link == ORE and 5 or 4 end
        _G.C_AuctionHouse = {
            GetItemCommodityStatus = function(loc) return loc.slot == 1 and 2 or 1 end,
            CalculateCommodityDeposit = function(itemID, duration, quantity)
                assert.equal(2770, itemID)
                return 15 * duration * quantity
            end,
            CalculateItemDeposit = function(loc, duration, quantity)
                assert.equal(2, loc.slot)
                return 60 * duration * quantity
            end,
            PostItem = function() posted = posted + 1 end,
            PostCommodity = function() posted = posted + 1 end,
        }
    end)
    after_each(function()
        for _, name in ipairs(STUBBED) do _G[name] = saved[name] end
    end)

    it("lists stack and one-unit deposits for each duration, commodity or item", function()
        _G.AuctionHouseFrame = CreateFrame("Frame")
        _G.AuctionHouseFrame:Show()
        local text = report(ns)
        has(text, "S8 AuctionHouseFrame shown = true")
        has(text, 'S8 deposit 0/1 id=2770 "Copper Ore" commodity sell=5 x5: stack 12h=75 24h=150 48h=225'
            .. ' | one 12h=15 24h=30 48h=45')
        has(text, 'S8 deposit 0/2 id=6256 "Fishing Pole" item sell=4 x1: stack 12h=60 24h=120 48h=180'
            .. ' | one 12h=60 24h=120 48h=180')
        assert.equal(0, posted, "the probe never posts an auction")
    end)

    it("skips soulbound and quest items", function()
        local text = report(ns)
        assert.falsy(text:find("Hearthstone", text:find("S8 ", 1, true), true))
        assert.falsy(text:find("Large Candle", text:find("S8 ", 1, true), true))
    end)

    it("says when the auction house isn't open", function()
        local text = report(ns)
        has(text, "S8 AuctionHouseFrame shown = missing (deposits need the auction house open)")
    end)
end)
