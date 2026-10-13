-- /rl probe "S5" lines (operator 2026-10-13): discovery for a second addon that
-- mails bag items worth more on the auction house (or disenchanted) to a bank
-- alt. Price-source addons, bag valuation, mail / auction / auto-complete /
-- gamepad-binding APIs. Read-only: nothing is mailed, bound or looked up.
local loadAddon = require("spec.support.load_addon")

local function report(ns)
    ns.HandleSlash("probe")
    return ns.ExportFrame.GetText()
end

local function has(text, needle)
    assert.truthy(text:find(needle, 1, true), "missing: " .. needle .. "\n---\n" .. text)
end

local STUBBED = { "C_AddOns", "Auctionator", "TSM_API", "DisenchantryDB", "C_Container", "GetItemInfo",
    "GetItemInfoInstant", "NUM_BAG_SLOTS", "MailFrame", "SendMailNameEditBox", "SendMail", "ClickSendMailItemButton",
    "GetSendMailPrice", "ATTACHMENTS_MAX_SEND", "AUTOCOMPLETE_FLAG_ALL", "GetAutoCompleteResults", "GetBindingAction",
    "SetOverrideBindingClick", "C_GamePad", "GetCVar", "SlashCmdList", "ItemLocation", "C_AuctionHouse" }

local LINEN = "|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"
local SWORD = "|cff1eff00|Hitem:15210::::::::60:::::|h[Raider's Shortsword]|h|r"

describe("/rl probe: S5 mailer discovery", function()
    local ns, saved, mailCalls
    before_each(function()
        ns = loadAddon()
        saved = {}
        for _, name in ipairs(STUBBED) do saved[name] = rawget(_G, name) end
        mailCalls = 0
        _G.SendMail = function() mailCalls = mailCalls + 1 end
        _G.ClickSendMailItemButton = function() mailCalls = mailCalls + 1 end
        _G.GetAutoCompleteResults = function() mailCalls = mailCalls + 1 return { { name = "Secret Friend" } } end
    end)
    after_each(function()
        for _, name in ipairs(STUBBED) do _G[name] = saved[name] end
    end)

    it("reports price addons, their saved tables and APIs", function()
        local loaded = { Auctionator = true, Disenchantry = true }
        _G.C_AddOns = {
            IsAddOnLoaded = function(name) return loaded[name] or false end,
            GetAddOnMetadata = function(name, field)
                if not loaded[name] then return nil end
                if field == "Version" then return name == "Auctionator" and "300.1" or "1.1.1" end
                if field == "SavedVariables" and name == "Disenchantry" then return "DisenchantryDB" end
            end,
        }
        _G.DisenchantryDB = { history = {}, version = 3 }
        _G.Auctionator = { API = { v1 = {
            GetAuctionPriceByItemLink = function() return 4500 end,
            GetDisenchantPriceByItemLink = function() return 900 end,
        } } }
        local text = report(ns)
        has(text, 'S5 addon Auctionator: loaded=true version="300.1"')
        has(text, "S5 addon TradeSkillMaster: loaded=false")
        has(text, "S5 Disenchantry saved DisenchantryDB keys: history(table), version(number)")
        has(text, "S5 Auctionator.API.v1 functions: GetAuctionPriceByItemLink, GetDisenchantPriceByItemLink")
        has(text, "S5 TSM_API functions: missing")
        has(text, "S5 globals matching disenchant|enchantry: DisenchantryDB(table)")
    end)

    it("values every bag item from vendor, Auctionator and TSM", function()
        _G.NUM_BAG_SLOTS = 1
        local bags = {
            [0] = { [1] = { itemID = 2589, hyperlink = LINEN, stackCount = 12, quality = 1, isBound = false,
                hasNoValue = false, isLocked = false } },
            [1] = { [2] = { itemID = 15210, hyperlink = SWORD, stackCount = 1, quality = 2, isBound = false } },
        }
        _G.C_Container = {
            GetContainerNumSlots = function(bag) return bag == 0 and 16 or 6 end,
            GetContainerNumFreeSlots = function(bag) return bag == 0 and 15 or 5 end,
            GetContainerItemInfo = function(bag, slot) return bags[bag] and bags[bag][slot] end,
            GetContainerItemQuestInfo = function() return { isQuestItem = false } end,
        }
        local sell = { [LINEN] = 13, [SWORD] = 1520 }
        _G.GetItemInfo = function(link) return "x", link, 1, 1, 1, "t", "s", 20, "", 0, sell[link] end
        _G.GetItemInfoInstant = function(link)
            if link == SWORD then return 15210, "Weapon", "Swords", "INVTYPE_WEAPON", 0, 2, 7 end
            return 2589, "Tradeskill", "Cloth", "", 0, 7, 5
        end
        _G.Auctionator = { API = { v1 = {
            GetAuctionPriceByItemLink = function(caller, link)
                assert.equal("LedgerLink", caller)
                return link == LINEN and 35 or nil
            end,
            GetDisenchantPriceByItemLink = function(_, link) if link == SWORD then error("no enchant data") end end,
        } } }
        _G.Auctionator.API.v1.GetAuctionAgeByItemLink = function(_, link) if link == LINEN then return 2 end error("x") end
        _G.Auctionator.API.v1.IsAuctionDataExactByItemLink = function() return true end
        _G.ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
        _G.C_AuctionHouse = { GetItemCommodityStatus = function(loc) return loc.bag == 0 and 1 or 2 end }
        _G.TSM_API = { ToItemString = function() return "i:2589" end, GetCustomPriceValue = function() return 40 end }
        local text = report(ns)
        has(text, "S5 bags: NUM_BAG_SLOTS=1")
        has(text, "S5 bag 0: 16 slots, 15 free")
        has(text, "S5 GetContainerItemInfo fields: hasNoValue(boolean), hyperlink(string)")
        has(text, 'S5 item 0/1 id=2589 "Linen Cloth" x12 quality=1 bound=false noValue=false locked=false quest=false'
            .. ' class=7/5 equip="" sell=13 ah=35 ahAge=2 ahExact=true de=nil commodity=1 tsmMarket=40')
        has(text, 'S5 item 1/2 id=15210 "Raider\'s Shortsword" x1 quality=2')
        has(text, 'class=2/7 equip="INVTYPE_WEAPON" sell=1520 ah=nil ahAge=error: ')
        has(text, 'ahExact=true de=error: ')
        has(text, 'no enchant data commodity=2 tsmMarket=40')
    end)

    it("reports mail, auto-complete and gamepad APIs without using them or printing names", function()
        _G.MailFrame = CreateFrame("Frame")
        _G.MailFrame:Show()
        _G.SendMailNameEditBox = { autoCompleteParams = { include = 7, exclude = 0 } }
        _G.GetSendMailPrice = function() return 30 end
        _G.ATTACHMENTS_MAX_SEND = 12
        _G.AUTOCOMPLETE_FLAG_ALL = 4294967295
        _G.SetOverrideBindingClick = function() end
        _G.GetBindingAction = function(key) return key == "PAD1" and "JUMP" or "" end
        _G.GetCVar = function(name) return name == "GamePadEnable" and "1" or nil end
        local text = report(ns)
        has(text, "S5 MailFrame shown = true")
        has(text, "S5 GetSendMailPrice() = 30")
        has(text, "S5 ATTACHMENTS_MAX_SEND = number 12")
        has(text, "S5 SendMail = function")
        has(text, "S5 SendMailNameEditBox.autoCompleteParams = {exclude = 0, include = 7}")
        has(text, "S5 AUTOCOMPLETE_ constants: AUTOCOMPLETE_FLAG_ALL=4294967295")
        has(text, 'S5 GetCVar("GamePadEnable") = "1"')
        has(text, "S5 gamepad bindings: PAD1=JUMP, PAD2=-")
        has(text, "S5 SetOverrideBindingClick = function")
        has(text, "S5 global functions matching mail: ClickSendMailItemButton")
        assert.equal(0, mailCalls, "the probe never sends mail, attaches items or auto-completes names")
        assert.falsy(text:find("Secret Friend", 1, true))
    end)

    it("still completes with none of the S5 APIs present", function()
        local text = report(ns)
        has(text, "S5 addon Auctionator: loaded=nil")
        has(text, "S5 bags: NUM_BAG_SLOTS=nil C_Container.GetContainerItemInfo=nil")
        has(text, "S5 C_Container.SortBags = missing")
        has(text, "S5 gamepad bindings: PAD1=missing")
    end)
end)
