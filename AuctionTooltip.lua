-- Craftonomics: item tooltips show what a vendor charges and pays for the item,
-- what it sells for with the price you picked (TSM's price type, or Auctionator),
-- what it costs to craft, TSM's sale rate and trend, its lowest auction against its
-- market value (with a Cheap or Expensive hint), and the auction house deposit for
-- posting it, so you can tell whether it's worth putting up. A material also shows
-- the best craft you can make with it. Each line has its own option.
local _, ns = ...

local format = string.format

-- The auction durations, by the game's number for them: Retail's, or WoW Forever's.
local DURATIONS = ns.QUALITY_CRAFTING and { "12h", "24h", "48h" } or { "2h", "8h", "24h" }

-- TSM's price types, as the tooltip names them.
local TSM_NAMES = {
	dbmarket = "Market Value",
	dbminbuyout = "Lowest Auction",
	[ns.TSM_LOWER] = "Lower of Market and Lowest",
	dbhistorical = "Historical Price",
	dbregionmarketavg = "Region Market Average",
}

-- Items that can't go on the auction house: bound when picked up, quest items,
-- bound to your account.
local ItemBind = Enum and Enum.ItemBind or {}
local UNSELLABLE_BINDS = {
	[ItemBind.OnAcquire or 1] = true,
	[ItemBind.Quest or 4] = true,
	[ItemBind.ToWoWAccount or 7] = true,
	[ItemBind.ToBnetAccount or 8] = true,
	[ItemBind.ToBnetAccountUntilEquipped or 9] = true,
}

-- Bonus IDs on raid zone drops can turn a BoP template into a BoE (or Warbound
-- until equipped) item, so tooltip binding text overrides the base template.
local BOUND_LINES = {}
local TRADEABLE_LINES = {}
for _, globalName in ipairs({
	"ITEM_SOULBOUND",
	"ITEM_BIND_ON_PICKUP",
	"ITEM_BIND_QUEST",
	"ITEM_ACCOUNTBOUND",
	"ITEM_BNETACCOUNTBOUND",
	"ITEM_ACCOUNTBOUND_UNTIL_EQUIP",
	"ITEM_BIND_TO_ACCOUNT",
	"ITEM_BIND_TO_BNETACCOUNT",
	"ITEM_BIND_TO_ACCOUNT_UNTIL_EQUIP",
}) do
	local text = _G[globalName]
	if type(text) == "string" and text ~= "" then BOUND_LINES[text] = true end
end
for _, globalName in ipairs({ "ITEM_BIND_ON_EQUIP", "ITEM_BIND_ON_USE" }) do
	local text = _G[globalName]
	if type(text) == "string" and text ~= "" then TRADEABLE_LINES[text] = true end
end

-- The game's money text, with a minus for a loss: it can't show one by itself
-- (a loss of 16s 66c came out as 83s 34c).
local function money(copper)
	copper = math.floor(copper + 0.5)
	local text = GetMoneyString(math.abs(copper), true)
	return copper < 0 and ("-" .. text) or text
end

-- Whether the game takes `location` as an item that's there. The game can hand
-- back a location it then refuses even to check, so a refusal counts as no.
local function exists(location)
	return location:IsValid() and C_Item.DoesItemExist(location)
end

-- Where a tooltip's item sits in your bags or bank, or nil (a link, a vendor's item...).
local function locationOf(data)
	local guid = data and data.guid
	if not guid or (issecretvalue and issecretvalue(guid)) or not C_Item.GetItemLocation then return end
	local ok, location = pcall(C_Item.GetItemLocation, guid)
	if not (ok and location) then return end
	local found, there = pcall(exists, location)
	if found and there then return location end
end

-- Binding state directly from the tooltip's rendered lines, so bonus IDs that
-- flip BoP <-> BoE or add Warbound Until Equipped win over base item data.
-- Returns true if bound/unsellable, false if explicitly tradeable, nil if unknown.
local function tooltipBindState(data)
	local lines = data and data.lines
	if type(lines) ~= "table" then return nil end
	for _, line in ipairs(lines) do
		local text = line and line.leftText
		if text and not (issecretvalue and issecretvalue(text)) then
			if BOUND_LINES[text] then return true end
			if TRADEABLE_LINES[text] then return false end
		end
	end
	return nil
end

-- Whether the item can't be posted: bound, Warbound, or a quest item.
local function unsellable(itemID, link, location, data)
	if location and C_Item.IsBound(location) then return true end
	local fromTooltip = tooltipBindState(data)
	if fromTooltip ~= nil then return fromTooltip end
	local bind = select(14, C_Item.GetItemInfo(link or itemID))
	return bind ~= nil and UNSELLABLE_BINDS[bind] == true
end

-- The raw deposit in copper for `qty` at each duration, or nil when the game won't say.
-- An item in your bags asks as that item; otherwise by its itemID, as the
-- auction house does for stackable goods.
local function rawDeposits(itemID, location, qty)
	local list = {}
	for duration = 1, #DURATIONS do
		local ok, deposit
		if location then
			ok, deposit = pcall(C_AuctionHouse.CalculateItemDeposit, location, duration, qty)
		end
		if not (ok and deposit) then
			ok, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, duration, qty)
		end
		if not (ok and type(deposit) == "number") then return end
		list[duration] = deposit
	end
	return list
end

local function formatDeposits(raw)
	local list = {}
	for duration = 1, #raw do list[duration] = money(raw[duration]) end
	return list
end

-- What the price line calls the price: "TSM Market Value" or "Auctionator".
local function sourceName(from)
	if from == "auctionator" then return "Auctionator" end
	if from == "own" then return "Craftonomics scan" end
	return "TSM " .. (TSM_NAMES[ns.db.saleSource] or ns.db.saleSource)
end

-- Profession icons found so far: professionID -> icon, or false for none.
local professionIcons = {}

-- A profession's icon, or nil when the game doesn't say. The number can be the
-- profession's own (Engineering) or one of its parts' (an expansion's), which
-- has its parent's icon. Failing that, it's looked up among your professions.
local function professionIcon(professionID)
	if not professionID then return end
	local icon = professionIcons[professionID]
	if icon ~= nil then return icon or nil end
	local texture, info = C_TradeSkillUI.GetTradeSkillTexture, C_TradeSkillUI.GetProfessionInfoBySkillLineID
	local ok, found = pcall(texture or error, professionID)
	icon = ok and found or nil
	local okInfo, part = pcall(info or error, professionID)
	local parent = okInfo and part and part.parentProfessionID
	if not icon and parent and parent > 0 then
		ok, found = pcall(texture or error, parent)
		icon = ok and found or nil
	end
	if not icon and GetProfessions and GetProfessionInfo then
		local profs = { GetProfessions() }
		for i = 1, 5 do
			local index = profs[i]
			if index then
				local _, mine, _, _, _, _, skillLine = GetProfessionInfo(index)
				if skillLine == professionID or (parent and skillLine == parent) then icon = mine end
			end
		end
	end
	professionIcons[professionID] = icon or false
	return icon
end

-- Whether a line with an Always / Never / While holding Shift choice shows now.
local function shown(choice)
	return choice == "always" or (choice ~= "never" and IsShiftKeyDown())
end

-- The game's number for recipe items: patterns, plans, schematics...
local RECIPE_CLASS = Enum.ItemClass and Enum.ItemClass.Recipe or 9

local function onItem(tooltip, data)
	local db = ns.db
	if not db or not C_AuctionHouse then return end
	if not (db.tipVendorBuy or db.tipVendorSell or db.tipAuction or db.tipMarketValue or db.tipCraftCost
		or db.tipCraftVsAH or db.tipDeposit or db.tipExpectedDeposit or db.tipSaleRate or db.tipTrend
		or db.tipLowest or db.tipBestCraft or db.tipRecipe) then
		return
	end
	local itemID = data and data.id
	if type(itemID) ~= "number" or (issecretvalue and issecretvalue(itemID)) then return end
	local location = locationOf(data)
	local _, link = TooltipUtil.GetDisplayedItem(tooltip)
	if link and issecretvalue and issecretvalue(link) then link = nil end
	if not link and location and C_Item.GetItemLink then
		local ok, bagLink = pcall(C_Item.GetItemLink, location)
		if ok and bagLink and not (issecretvalue and issecretvalue(bagLink)) then link = bagLink end
	end
	-- A recipe's tooltip also shows the item it makes, and on a vendor the game can
	-- hand back that item's link instead of the recipe's: price the recipe itself.
	if link and C_Item.GetItemInfoInstant(link) ~= itemID then link = nil end
	-- The auction lines only for items you can post.
	local postable = not unsellable(itemID, link, location, data)
	local count = location and C_Item.GetStackCount(location) or 1
	-- A stack in your bags shows the whole stack's amounts only while Shift is held.
	-- Nothing here redraws the tooltip when Shift changes: the game redraws a bag
	-- item's tooltip several times a second by itself. Redrawing it from addon code
	-- (tooltip:RefreshData()) was taken out in case it's what blocked using an item
	-- from the bags ("tried to call the protected function" on a right-click).
	local qty = (count > 1 and IsShiftKeyDown()) and count or 1
	local stack = qty > 1 and format(" (x%d)", qty) or ""

	-- What a vendor charges for one (nil when no vendor sells it, or nobody knows),
	-- and what a vendor pays for one (nil when a vendor won't buy it).
	local vendorBuy = db.tipVendorBuy and ns.Prices.Vendor(itemID) or nil
	local vendorSell = db.tipVendorSell and select(11, C_Item.GetItemInfo(link or itemID)) or nil
	if vendorSell and vendorSell <= 0 then vendorSell = nil end
	local itemKey = link or ("item:" .. itemID)
	-- Saved TSM prices already have their own line (Show saved TSM prices).
	local ahPrice, from
	if postable and (db.tipAuction or db.tipCraftVsAH) then ahPrice, from = ns.Prices.SaleFrom(itemKey, itemID) end
	local price = (db.tipAuction and from ~= "saved") and ahPrice or nil
	local marketValue, marketFrom
	if postable and db.tipMarketValue then
		marketValue, marketFrom = ns.Prices.MarketValue(itemKey, itemID)
		if marketFrom == "tsm" and price and from == "tsm" then marketValue = nil end
	end
	local craftCost = (db.tipCraftCost or db.tipCraftVsAH) and ns.AllRecipes and ns.AllRecipes.CraftCost
		and ns.AllRecipes.CraftCost(itemID) or nil
	local showCraftCost = db.tipCraftCost and craftCost or nil
	local craftVsAH
	if postable and db.tipCraftVsAH and craftCost and craftCost > 0 and ahPrice and ahPrice > 0 then
		local netAH = db.ahCut and (ahPrice * (1 - ns.AH_CUT)) or ahPrice
		craftVsAH = math.floor((netAH - craftCost) * 100 / craftCost + 0.5)
	end
	local rawDeps = postable and (db.tipDeposit or db.tipExpectedDeposit) and rawDeposits(itemID, location, qty) or nil
	local list = db.tipDeposit and rawDeps and formatDeposits(rawDeps) or nil
	-- The share of its auctions that sell, from TSM or your own auction mail history.
	local rate, rateFrom, rateSold, rateTotal
	if postable and (db.tipSaleRate or db.tipExpectedDeposit) then
		rate, rateFrom, rateSold, rateTotal = ns.Prices.SaleRate(itemKey, itemID)
	end
	local showRate = db.tipSaleRate and rate or nil
	local expectedDepositText
	if postable and db.tipExpectedDeposit and rawDeps and rate and rate > 0 and ns.Prices.ExpectedDeposit then
		local minSamples = ns.Sales and ns.Sales.MIN_DECISION_SAMPLES or 3
		if rateFrom == "tsm" or (rateTotal or 0) >= minSamples then
			if rate >= 1 then
				expectedDepositText = ns.Color("muted", "None (100%)")
			else
				local parts = {}
				for i = 1, #rawDeps do parts[i] = money(ns.Prices.ExpectedDeposit(rawDeps[i], rate)) end
				expectedDepositText = table.concat(parts, " / ")
			end
		end
	end
	-- How far its market value is from its historical price, from TSM or scan history.
	local trend, trendFrom
	if postable and db.tipTrend then trend, trendFrom = ns.Prices.Trend(itemKey, itemID) end
	-- How far its lowest auction is from its market value, and whose lowest/market prices are used.
	local lowest, lowestFrom, lowestMarketFrom
	if postable and db.tipLowest then
		lowest, lowestFrom, lowestMarketFrom = ns.Prices.LowestVsMarket(itemKey, itemID)
	end
	-- For a material: the most profitable recipe this character knows that takes it.
	-- Only when it makes gold: the best of recipes that all lose it is nothing to craft.
	local best = db.tipBestCraft and ns.BestCrafts.BestWith(itemID) or nil
	if best and (best.profit <= 0 or best.score <= 0) then best = nil end
	-- For a recipe item: the recipe it teaches, priced as the All recipes window
	-- prices it. A loss shows too: it's what to know before buying one.
	local recipe
	if db.tipRecipe and select(6, C_Item.GetItemInfoInstant(itemID)) == RECIPE_CLASS then
		recipe = ns.AllRecipes.Scroll(itemID)
	end
	if not (vendorBuy or vendorSell or price or marketValue or showCraftCost or craftVsAH or list or expectedDepositText
		or showRate or trend or lowest or best or recipe) then
		return
	end

	tooltip:AddLine(" ")
	if vendorBuy then tooltip:AddDoubleLine("Vendor Buy", money(vendorBuy), 1, 0.82, 0, 1, 1, 1) end
	if vendorSell then
		tooltip:AddDoubleLine("Vendor Sell", money(vendorSell), 1, 0.82, 0, 1, 1, 1)
		if qty > 1 then tooltip:AddDoubleLine("  For" .. stack, money(vendorSell * qty), 0.53, 0.53, 0.53, 1, 1, 1) end
	end
	if price then
		tooltip:AddDoubleLine(sourceName(from), money(price), 1, 0.82, 0, 1, 1, 1)
		if qty > 1 then tooltip:AddDoubleLine("  For" .. stack, money(price * qty), 0.53, 0.53, 0.53, 1, 1, 1) end
	end
	if marketValue then
		tooltip:AddDoubleLine("Market Value", money(marketValue), 1, 0.82, 0, 1, 1, 1)
		if qty > 1 then tooltip:AddDoubleLine("  For" .. stack, money(marketValue * qty), 0.53, 0.53, 0.53, 1, 1, 1) end
	end
	if showCraftCost then
		tooltip:AddDoubleLine("Craft Cost", money(showCraftCost), 1, 0.82, 0, 1, 1, 1)
		if qty > 1 then tooltip:AddDoubleLine("  For" .. stack, money(showCraftCost * qty), 0.53, 0.53, 0.53, 1, 1, 1) end
	end
	if craftVsAH then
		tooltip:AddDoubleLine("Craft vs AH", ns.Format.CraftVsAH(craftVsAH), 1, 0.82, 0, 1, 1, 1)
	end
	if showRate then
		local tsm = rateFrom == "tsm" or (rateFrom == nil and ns.Prices.SaleRateSource and ns.Prices.SaleRateSource() == "tsm")
		local label = tsm and "TSM Sale Rate" or "Your Sale Rate"
		local value = ns.Format.SaleRate(showRate)
		if not tsm and rateSold and rateTotal then
			value = value .. " " .. ns.Color("muted", format("(%d/%d)", rateSold, rateTotal))
		end
		tooltip:AddDoubleLine(label, value, 1, 0.82, 0, 1, 1, 1)
	end
	if trend then
		tooltip:AddDoubleLine(trendFrom == "tsm" and "TSM Trend" or "Trend", ns.Format.Trend(trend), 1, 0.82, 0, 1, 1, 1)
	end
	if lowest then
		local label
		if lowestMarketFrom == "tsm" then
			label = lowestFrom == "tsm" and "TSM Lowest vs Market" or "Lowest vs TSM Market"
		else
			label = "Lowest vs Market"
		end
		tooltip:AddDoubleLine(label, ns.Format.LowestVsMarket(lowest), 1, 0.82, 0, 1, 1, 1)
	end
	if list then
		tooltip:AddDoubleLine("AH Deposit " .. table.concat(DURATIONS, " / ") .. stack, table.concat(list, " / "),
			1, 0.82, 0, 1, 1, 1)
	end
	if expectedDepositText then
		tooltip:AddDoubleLine("Expected Deposit " .. table.concat(DURATIONS, " / ") .. stack, expectedDepositText,
			1, 0.82, 0, 1, 1, 1)
	end
	if best then
		-- What one craft of the last recipe in the chain makes.
		tooltip:AddDoubleLine("Best Craft", ns.Color("profit", "+" .. money(best.profit)), 1, 0.82, 0, 1, 1, 1)
		-- Under it, the chain of crafts that gets there, each set in further than the
		-- one before: its profession's icon and what it makes (by the item's own
		-- name once the game has it).
		for index, step in ipairs(best.steps) do
			local name = step.itemID and ns.Format.ItemName(step.itemID)
			name = name and ns.Format.RarityColored(step.itemID, name) or step.name
			local icon = professionIcon(step.professionID)
			tooltip:AddLine(string.rep("  ", index) .. (icon and format("|T%s:0|t ", icon) or "") .. name, 1, 1, 1)
		end
		-- The craft's return: its profit as a share of what its materials cost.
		local share = shown(db.tipBestShowReturn) and ns.Format.ReturnShare(best.profit, best.cost)
		if share then
			tooltip:AddDoubleLine("  Return", ns.Format.Return(share), 0.53, 0.53, 0.53, 1, 1, 1)
		end
		-- How well what it makes sells, from TSM or your own auction mail history.
		if best.saleRate and shown(db.tipBestRate) then
			local tsm = best.saleRateFrom == "tsm"
				or (best.saleRateFrom == nil and ns.Prices.SaleRateSource and ns.Prices.SaleRateSource() == "tsm")
			local label = tsm and "  TSM Sale Rate" or "  Your Sale Rate"
			local value = ns.Format.SaleRate(best.saleRate)
			if not tsm and best.saleRateSold and best.saleRateTotal then
				value = value .. " " .. ns.Color("muted", format("(%d/%d)", best.saleRateSold, best.saleRateTotal))
			end
			tooltip:AddDoubleLine(label, value, 0.53, 0.53, 0.53, 1, 1, 1)
		end
	end
	if recipe then
		-- What one craft of it makes or loses, and under it what it makes, as Best Craft
		-- shows a craft. The return and sale rate follow Best Craft's choices.
		local net = recipe.net
		tooltip:AddDoubleLine("Recipe Profit", ns.Color(ns.AmountColor(net), (net > 0 and "+" or "") .. money(net)),
			1, 0.82, 0, 1, 1, 1)
		local icon = professionIcon(recipe.professionID)
		tooltip:AddLine("  " .. (icon and format("|T%s:0|t ", icon) or "")
			.. ns.Format.RarityColored(recipe.itemID, recipe.name), 1, 1, 1)
		local share = shown(db.tipBestShowReturn) and ns.Format.ReturnShare(net, recipe.cost)
		if share then tooltip:AddDoubleLine("  Return", ns.Format.Return(share), 0.53, 0.53, 0.53, 1, 1, 1) end
		if recipe.saleRate and shown(db.tipBestRate) then
			local tsm = recipe.saleRateFrom == "tsm"
				or (recipe.saleRateFrom == nil and ns.Prices.SaleRateSource and ns.Prices.SaleRateSource() == "tsm")
			local label = tsm and "  TSM Sale Rate" or "  Your Sale Rate"
			local value = ns.Format.SaleRate(recipe.saleRate)
			if not tsm and recipe.saleRateSold and recipe.saleRateTotal then
				value = value .. " " .. ns.Color("muted", format("(%d/%d)", recipe.saleRateSold, recipe.saleRateTotal))
			end
			tooltip:AddDoubleLine(label, value, 0.53, 0.53, 0.53, 1, 1, 1)
		end
	end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onItem)
