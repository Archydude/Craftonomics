-- Craftonomics: every profession's recipes, priced as if you bought the
-- materials and sold what a craft makes, whether or not a character of yours
-- knows the recipe. For the All recipes window (AllRecipesWindow.lua). The recipes
-- are unpacked and priced a few at a time while the window is open, and let go
-- when it closes.
--
-- WoW Forever: all of them at once, from Data\ForeverRecipes.lua, which has what
-- each takes and makes. An enchant makes nothing to sell there: it has only what
-- its materials cost.
--
-- Retail: one expansion at a time, from Data\RetailRecipes.lua, which only says
-- which recipes there are: the game says what each takes and makes. A recipe with
-- ranks is priced at its highest rank with the best materials, or at its lowest
-- with the cheapest (ns.db.recipesRank): nobody's skill is there to say which rank
-- a craft would come out at.
--
-- A recipe item's tooltip (a pattern, plan, schematic...) asks for the one recipe
-- it teaches, priced the same way, without the window (AllRecipes.Scroll).
local _, ns = ...

local AllRecipes = {}
ns.AllRecipes = AllRecipes

-- Pricing works this long each frame, then waits for the next one.
local FRAME_BUDGET_MS = 4

-- Every recipe while the window is open: {
--   recipeID, itemID, link = the item as price addons are asked about it (an
--   enchant, which makes no item, has neither, and enchant = true),
--   made = how many one craft makes (the average, for recipes that make a range),
--   professionID, profession = its name, materials = { { itemID, qty } ... }
--   (on Retail a material that comes in several also has options = their item IDs,
--   lowest quality first, and qualities = true when they're one material's
--   qualities; itemID is then the one the craft is priced with),
--   rank = the rank it's priced at, and highest = whether that's its highest (Retail,
--   rank nil for a recipe without ranks),
--   recipeName, name = the item's (the recipe's until the game has loaded it),
--   required = the skill the recipe needs (nil for one a trainer teaches: the game
--   data doesn't have it), yellow and grey = the skills where it turns yellow and
--   grey (nil when the data has neither), skill = what the Skill column shows and
--   sorts by: required, or else yellow,
--   -- once priced:
--   each = what one item sells for (nil without a price), gross = what a craft's
--   items sell for after the auction house cut, cost = the materials (nil when one
--   has no price), unpriced = how many of them have none, net = gross - cost,
--   saleRate and soldPerDay = TSM's (nil without), market and historical = TSM's
--   market value and historical price of one (both, or neither). An enchant has
--   only cost and unpriced,
-- }
local rows
local byItem -- itemID -> the rows that make it (a few items have two recipes)
-- Every material's name in lower case, for the search: itemID -> name, or false
-- until the game has loaded the item.
local materialNames
-- What TSM says about each material, for the heatmap: itemID -> { itemID, market,
-- historical, soldPerDay, saleRate }, or false for one without both prices. Nil until every
-- recipe is priced, and without TSM on this character.
local materials
-- The pricing in progress or finished: { done, total, finished, buy and keep = what
-- it prices with (see priceRow) }.
local run
local deadline = 0 -- when this frame's share of the pricing runs out

local function pauseIfDue()
	if debugprofilestop() > deadline then coroutine.yield() end
end

-- A profession's name, in the game's language when the game or the data has it.
function AllRecipes.ProfessionName(professionID)
	if ns.QUALITY_CRAFTING then
		local name = C_TradeSkillUI.GetTradeSkillDisplayName and C_TradeSkillUI.GetTradeSkillDisplayName(professionID)
		return name and name ~= "" and name or ns.RECIPE_PROFESSIONS[professionID]
	end
	local names = ns.RECIPE_PROFESSION_NAMES[GetLocale()]
	return names and names[professionID] or ns.RECIPE_PROFESSIONS[professionID]
end

-- The professions with recipes here: { { id, name } ... }, by name.
function AllRecipes.Professions()
	local list = {}
	for professionID in pairs(ns.RECIPE_PROFESSIONS) do
		list[#list + 1] = { id = professionID, name = AllRecipes.ProfessionName(professionID) }
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

-- Retail: the expansions with recipes: { { id, name } ... }, newest first. The
-- name is the game's own for the expansion, in its language.
function AllRecipes.Expansions()
	local list = {}
	for id, name in pairs(ns.RECIPE_EXPANSIONS or {}) do
		list[#list + 1] = { id = id, name = _G["EXPANSION_NAME" .. id] or name }
	end
	table.sort(list, function(a, b) return a.id > b.id end)
	return list
end

-- Retail: the expansion whose recipes the window lists: the one you picked, or
-- the newest.
function AllRecipes.Expansion()
	local picked = ns.db.recipesExpansion
	if picked and ns.RETAIL_RECIPES[picked] then return picked end
	local newest
	for id in pairs(ns.RETAIL_RECIPES) do
		if not newest or id > newest then newest = id end
	end
	return newest
end

-- Retail: whether recipes with ranks are priced at their highest rank with the
-- best materials (otherwise at their lowest, with the cheapest).
function AllRecipes.Highest()
	return ns.db.recipesRank ~= "lowest"
end

-- One line of the data ("recipe:item:made:skill needed:material.count,...") as a row, or nil.
local function unpackRecipe(text, professionID, profession)
	local recipeID, itemID, made, required, packed = text:match("^(%d+):(%d+):([%d.]+):(%d+):(.+)$")
	if not recipeID then return end
	local materials = {}
	for material, qty in packed:gmatch("(%d+)%.(%d+)") do
		materials[#materials + 1] = { itemID = tonumber(material), qty = tonumber(qty) }
	end
	recipeID, itemID, required = tonumber(recipeID), tonumber(itemID), tonumber(required)
	if required == 0 then required = nil end
	-- Item 0: an enchant, which makes no item.
	local enchant = itemID == 0
	if enchant then itemID = nil end
	-- Where it turns yellow and grey, from the skill-up data (Data\Forever.lua).
	local colors = ns.SKILLUPS and ns.SKILLUPS[recipeID]
	local yellow, grey = colors and colors[1], colors and colors[2]
	if yellow == 0 then yellow = nil end
	if grey == 0 then grey = nil end
	local recipeName = C_Spell.GetSpellName(recipeID)
	return { recipeID = recipeID, itemID = itemID, link = itemID and "item:" .. itemID, enchant = enchant,
		made = tonumber(made),
		professionID = professionID, profession = profession, materials = materials,
		required = required, yellow = yellow, grey = grey, skill = required or yellow,
		recipeName = recipeName, name = recipeName or "?" }
end

-- Retail: the item a recipe makes at a rank (nil for a recipe without ranks):
-- link and itemID, or nil. An enchant makes its scroll.
local function retailOutput(recipeID, name, scroll, qualityIDs, rank)
	if scroll then
		local link, itemID = ns.Blizzard.ScrollAt(recipeID, name, rank)
		-- The scrolls can have fewer ranks than the game says the recipe has.
		if not itemID then link, itemID = ns.Blizzard.ScrollAt(recipeID, name) end
		return link, itemID
	end
	local ok, output = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, {}, nil, rank and qualityIDs[rank])
	if ok and output and (output.itemID or 0) > 0 then
		local link = output.hyperlink
		if not link then
			if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(output.itemID) end
			link = "item:" .. output.itemID
		end
		return link, output.itemID
	end
end

-- Retail: one recipe as a row, from what the game says about it, or nil when it
-- makes nothing to sell. `highest`: see AllRecipes.Highest.
local function retailRow(recipeID, professionID, profession, highest)
	local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
	if not schematic then return end
	local scroll = ns.Blizzard.MakesScroll(recipeID)
	if scroll then
		schematic = ns.Blizzard.ScrollSchematic(schematic)
	elseif schematic.recipeType ~= Enum.TradeskillRecipeType.Item then
		return
	end

	local qualityIDs = C_TradeSkillUI.GetQualitiesForRecipe(recipeID)
	local ranks = qualityIDs and #qualityIDs or 0
	local rank = ranks > 1 and (highest and ranks or 1) or nil
	local link, itemID = retailOutput(recipeID, schematic.name, scroll, qualityIDs, rank)
	if not itemID then return end

	-- What it needs: every required slot, with all the items that can fill it.
	local materials = {}
	for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
		if slot.required then
			local options = {}
			for _, reagent in ipairs(slot.reagents or {}) do
				if reagent.itemID then options[#options + 1] = reagent.itemID end
			end
			if #options > 0 then
				materials[#materials + 1] = { itemID = options[1], qty = slot.quantityRequired or 1,
					options = #options > 1 and options or nil,
					qualities = #options > 1 and ns.Blizzard.IsQualitySlot(slot) or nil }
			end
		end
	end

	local name = schematic.name
	return { recipeID = recipeID, itemID = itemID, link = link, enchant = false,
		made = ((schematic.quantityMin or 1) + (schematic.quantityMax or 1)) / 2,
		professionID = professionID, profession = profession, materials = materials,
		rank = rank, highest = highest, recipeName = name, name = name or "?" }
end

-- Retail: which of a material's items a craft is priced with: the best quality at
-- the highest rank, and otherwise the cheapest (the first while none has a price).
local function pickMaterial(material, buy, highest)
	local options = material.options
	if highest and material.qualities then return options[#options] end
	local cheapest, lowest
	for _, itemID in ipairs(options) do
		local price = buy(itemID)
		if price and (not lowest or price < lowest) then cheapest, lowest = itemID, price end
	end
	return cheapest or options[1]
end

-- A material's name in lower case, or nil until the game has loaded it (it's
-- asked to, and AllRecipes.ItemArrived hears when it has).
local function materialName(itemID)
	local name = materialNames[itemID]
	if name then return name end
	name = C_Item.GetItemNameByID(itemID)
	if name then
		name = name:lower()
		materialNames[itemID] = name
		return name
	end
	if materialNames[itemID] == nil then
		materialNames[itemID] = false
		C_Item.RequestLoadItemDataByID(itemID)
	end
end

-- Whether one of the recipe's materials has `search` (lower case) in its name.
function AllRecipes.UsesMaterial(row, search)
	if not materialNames then return false end
	for _, material in ipairs(row.materials) do
		local name = materialName(material.itemID)
		if name and name:find(search, 1, true) then return true end
	end
	return false
end

-- Unpacks every recipe: all of WoW Forever's, or on Retail the shown expansion's,
-- asking the game about each (`this` is the pricing: it's told how far that is).
-- They only count once all are there: a pricing dropped halfway leaves nothing
-- behind.
local function unpackAll(this)
	local list, items = {}, {}
	local function add(row)
		if not row then return end
		list[#list + 1] = row
		if row.itemID then
			local same = items[row.itemID]
			if not same then
				same = {}
				items[row.itemID] = same
			end
			same[#same + 1] = row
		end
	end
	if ns.QUALITY_CRAFTING then
		local packed = ns.RETAIL_RECIPES[AllRecipes.Expansion()] or {}
		local highest = AllRecipes.Highest()
		-- Asking the game is the first half of the work, pricing the second.
		local count = 0
		for _, recipes in pairs(packed) do
			count = count + select(2, recipes:gsub("%d+", "")) -- how many recipes the text has
		end
		this.total = 2 * count
		for professionID, recipes in pairs(packed) do
			local profession = AllRecipes.ProfessionName(professionID)
			for recipeID in recipes:gmatch("%d+") do
				add(retailRow(tonumber(recipeID), professionID, profession, highest))
				this.done = this.done + 1
				pauseIfDue()
			end
		end
		this.scanned = count
	else
		for professionID, packed in pairs(ns.ALL_RECIPES) do
			local profession = AllRecipes.ProfessionName(professionID)
			for _, text in ipairs(packed) do
				add(unpackRecipe(text, professionID, profession))
				pauseIfDue()
			end
		end
	end
	rows, byItem, materialNames = list, items, {}
end

-- Fills in what a recipe's materials cost at today's prices: cost and unpriced.
-- `buy` is what buying a material costs (see Prices.Buy).
local function priceMaterials(row, buy)
	local cost, unpriced = 0, 0
	for _, material in ipairs(row.materials) do
		if material.options then material.itemID = pickMaterial(material, buy, row.highest) end
		-- Asked for now, so the window's search has it by the time you type.
		if materialNames then materialName(material.itemID) end
		local price = buy(material.itemID)
		if price then cost = cost + price * material.qty else unpriced = unpriced + 1 end
	end
	row.unpriced = unpriced
	row.cost = unpriced == 0 and cost or nil
end

-- Fills in what a recipe costs and makes at today's prices. `keep` is the share
-- of a sale the auction house leaves you.
local function priceRow(row, buy, keep)
	row.each, row.gross, row.cost, row.net, row.saleRate, row.soldPerDay = nil, nil, nil, nil, nil, nil
	row.ahCut, row.expectedDeposit, row.soldToVendor, row.vendorProceeds, row.depositDuration, row.ahNet =
		nil, nil, nil, nil, nil, nil
	row.cachedExpectedDeposit = nil
	row.saleRateFrom, row.saleRateSold, row.saleRateTotal = nil, nil, nil
	row.market, row.historical, row.listed = nil, nil, nil
	-- An enchant makes nothing to sell: only its materials have a price.
	if row.enchant then return priceMaterials(row, buy) end
	-- The item's own name, once the game has loaded it. Some prices need the item
	-- loaded too, so it's priced again then (see AllRecipes.ItemArrived).
	local name = ns.Format.ItemName(row.itemID)
	if name then row.name = name else C_Item.RequestLoadItemDataByID(row.itemID) end
	row.each = ns.Prices.Sale(row.link, row.itemID)
	-- Without a price the window leaves it out, so there's nothing more to ask.
	if not row.each then return end
	priceMaterials(row, buy)
	if ns.Prices.NetProceeds then
		local net, info = ns.Prices.NetProceeds(row.link, row.itemID, row.each, row.made)
		row.gross = net
		if info then
			row.ahCut = info.ahCut
			row.expectedDeposit = info.expectedDeposit
			row.soldToVendor = info.soldToVendor
			row.vendorProceeds = info.vendorProceeds
			row.depositDuration = info.duration
			row.ahNet = info.ahNet
		end
	else
		row.gross = row.each * row.made * keep
	end
	row.net = row.cost and row.gross - row.cost
	row.saleRate, row.saleRateFrom, row.saleRateSold, row.saleRateTotal = ns.Prices.SaleRate(row.link, row.itemID)
	row.soldPerDay = ns.Prices.SoldPerDay(row.link)
	row.market, row.historical = ns.Prices.MarketAndHistorical(row.link, row.itemID)
	if not row.soldPerDay and ns.Prices.HasTrend() then
		row.listed = ns.Prices.Listed(row.link)
	end
end

-- Asks TSM or scan history about every material of the recipes, each once (see `materials`).
local function priceMaterialItems()
	if not ns.Prices.HasTrend() then return end
	local list = {}
	for _, row in ipairs(rows) do
		for _, material in ipairs(row.materials) do
			local itemID = material.itemID
			if list[itemID] == nil then
				local link = "item:" .. itemID
				local market, historical = ns.Prices.MarketAndHistorical(link, itemID)
				local soldPerDay = ns.Prices.SoldPerDay(link)
				local listed = (not soldPerDay and historical) and ns.Prices.Listed(link) or nil
				local saleRate, saleRateFrom, saleRateSold, saleRateTotal = ns.Prices.SaleRate(link, itemID)
				list[itemID] = historical
					and { itemID = itemID, market = market, historical = historical,
						soldPerDay = soldPerDay, saleRate = saleRate, saleRateFrom = saleRateFrom,
						saleRateSold = saleRateSold, saleRateTotal = saleRateTotal, listed = listed }
					or false
				pauseIfDue()
			end
		end
	end
	materials = list
end

local function priceAll(this)
	if not rows then unpackAll(this) end
	-- On Retail, asking the game about each recipe came first and counts too.
	local scanned = this.scanned or 0
	this.total = scanned + #rows
	-- Most materials are in many recipes: each is asked about once. False is "no price".
	local known = {}
	local function buy(itemID)
		local price = known[itemID]
		if price == nil then
			price = ns.Prices.Buy(itemID) or false
			known[itemID] = price
		end
		return price or nil
	end
	local keep = ns.db.ahCut and (1 - ns.AH_CUT) or 1
	-- Kept for the recipes priced again when their item loads.
	this.buy, this.keep = buy, keep
	for index, row in ipairs(rows) do
		priceRow(row, buy, keep)
		this.done = scanned + index
		pauseIfDue()
	end
	materials = nil
	priceMaterialItems()
end

-- Prices every recipe again, a few each frame. `onChange` is called after each
-- frame's share with the pricing ({ done, total, finished }); the rows are whole
-- once it's finished. A pricing still going is dropped.
function AllRecipes.Price(onChange)
	local this = { done = 0, total = 0, finished = false }
	run = this
	local thread = coroutine.create(priceAll)
	local function step()
		if run ~= this then return end
		deadline = debugprofilestop() + FRAME_BUDGET_MS
		local ok, err = coroutine.resume(thread, this)
		if not ok then
			run = nil
			geterrorhandler()(err)
			return
		end
		if coroutine.status(thread) == "dead" then this.finished = true end
		onChange(this)
		if not this.finished then C_Timer.After(0, step) end
	end
	step()
end

-- The recipes once they're all priced, or nil until then.
function AllRecipes.Rows()
	return run and run.finished and rows or nil
end

-- What TSM says about a material of these recipes ({ itemID, market, historical,
-- soldPerDay, saleRate }), or nil: no TSM on this character, or it lacks one of the prices.
function AllRecipes.Material(itemID)
	return materials and materials[itemID] or nil
end

-- The game has loaded an item: its recipes go by its name from here on, and one
-- that had no price is priced again, since some prices need the item loaded.
-- A material's name is there for the search from here on. True when it's an item
-- or a material of these recipes: its name, color or price may show differently
-- now, or the search may find it.
function AllRecipes.ItemArrived(itemID)
	local isMaterial = false
	if materialNames and materialNames[itemID] == false then
		isMaterial = materialName(itemID) ~= nil
	end
	local same = byItem and byItem[itemID]
	if not same then return isMaterial end
	local name = ns.Format.ItemName(itemID)
	for _, row in ipairs(same) do
		if name then row.name = name end
		if not row.each and run and run.buy then priceRow(row, run.buy, run.keep) end
	end
	return true
end

---------------------------------------------------------------------------
-- Recipe items
---------------------------------------------------------------------------

-- How long a recipe item's craft keeps its prices, in seconds: a tooltip is drawn
-- again many times while it's up. Shorter while it has no profit to show, as the
-- game may still be loading what it makes.
local SCROLL_PRICED, SCROLL_UNPRICED = 5, 1
-- The recipe items asked about so far: itemID -> { recipeID, professionID, row =
-- its recipe as a row (see `rows`), highest = the rank choice it was made with,
-- due = when it's priced again }, or false for an item that teaches none of the
-- recipes here.
local scrolls = {}

-- The recipe an item teaches and its profession, from the data, or nil.
local function scrollRecipe(itemID)
	for professionID, packed in pairs(ns.RECIPE_SCROLLS or {}) do
		-- "item:recipe,item:recipe...": the item's number, whole, then its recipe's.
		local recipeID = packed:match("%f[%d]" .. itemID .. ":(%d+)")
		if recipeID then return tonumber(recipeID), professionID end
	end
end

-- That recipe as a row, or nil when it makes nothing to sell.
local function scrollRow(recipeID, professionID, highest)
	local profession = AllRecipes.ProfessionName(professionID)
	if ns.QUALITY_CRAFTING then return retailRow(recipeID, professionID, profession, highest) end
	local start = recipeID .. ":"
	for _, text in ipairs(ns.ALL_RECIPES[professionID] or {}) do
		if text:sub(1, #start) == start then return unpackRecipe(text, professionID, profession) end
	end
end

-- For a recipe item (a pattern, plan, schematic...): the recipe it teaches as a
-- priced row (see `rows`: net is one craft's profit, with cost, itemID, name,
-- professionID and saleRate), whether or not you know the recipe. Nil for any other
-- item, and while the recipe has no profit to show: no price for what it makes or
-- for one of its materials, or nothing made to sell (an enchant on WoW Forever).
function AllRecipes.Scroll(itemID)
	local scroll = scrolls[itemID]
	if scroll == nil then
		local recipeID, professionID = scrollRecipe(itemID)
		scroll = recipeID and { recipeID = recipeID, professionID = professionID } or false
		scrolls[itemID] = scroll
	end
	if not scroll then return end
	local now = GetTime()
	if not scroll.due or now >= scroll.due then
		-- Asked of the game on Retail, which can change its mind as it loads.
		local highest = AllRecipes.Highest()
		if not scroll.row or scroll.highest ~= highest then
			local ok, row = pcall(scrollRow, scroll.recipeID, scroll.professionID, highest)
			scroll.row, scroll.highest = ok and row or nil, highest
		end
		local row = scroll.row
		if row then priceRow(row, ns.Prices.Buy, ns.db.ahCut and (1 - ns.AH_CUT) or 1) end
		scroll.due = now + ((row and row.net) and SCROLL_PRICED or SCROLL_UNPRICED)
	end
	local row = scroll.row
	return row and row.net and row or nil
end

---------------------------------------------------------------------------
-- Craft cost on item tooltips
---------------------------------------------------------------------------

local MAX_CRAFT_DEPTH = 6
local foreverByItem
local retailItemRecipes = {}
local craftCosts = {}

local function foreverRecipesFor(itemID)
	if not foreverByItem then
		foreverByItem = {}
		for professionID, packed in pairs(ns.ALL_RECIPES or {}) do
			for _, text in ipairs(packed) do
				local recipeID, outID, made, matText = text:match("^(%d+):(%d+):([%d.]+):%d+:(.+)$")
				recipeID, outID, made = tonumber(recipeID), tonumber(outID), tonumber(made)
				if recipeID and outID and outID > 0 and made and made > 0 then
					local mats, selfRef = {}, false
					for material, qty in matText:gmatch("(%d+)%.(%d+)") do
						local matID = tonumber(material)
						if matID == outID then
							selfRef = true
							break
						end
						mats[#mats + 1] = { itemID = matID, qty = tonumber(qty) }
					end
					if not selfRef and #mats > 0 then
						local list = foreverByItem[outID]
						if not list then
							list = {}
							foreverByItem[outID] = list
						end
						list[#list + 1] = { recipeID = recipeID, professionID = professionID, made = made, materials = mats }
					end
				end
			end
		end
	end
	return foreverByItem[itemID]
end

local function foreverSubCost(matID, profID, depth, working)
	if ns.Chains and ns.Chains.Active and ns.Chains.Active()
		and ns.Chains.RecipeFor and ns.Chains.RecipeFor(matID) then
		return ns.Prices.Material(matID)
	end
	local strategy = ns.db.craftStrategy
	local buy = ns.Prices.Buy(matID)
	if (strategy ~= "craft" and strategy ~= "mix") or depth >= MAX_CRAFT_DEPTH or working[matID] then
		return buy
	end
	local candidates = foreverRecipesFor(matID)
	if not candidates then return buy end
	local subCraft
	working[matID] = true
	for _, sub in ipairs(candidates) do
		if sub.professionID == profID then
			local total, ok = 0, true
			for _, mat in ipairs(sub.materials) do
				local price = foreverSubCost(mat.itemID, profID, depth + 1, working)
				if not price then
					ok = false
					break
				end
				total = total + price * mat.qty
			end
			if ok then
				local unit = total / sub.made
				if not subCraft or unit < subCraft then subCraft = unit end
			end
		end
	end
	working[matID] = nil
	if strategy == "craft" then return subCraft or buy end
	if subCraft and buy then return math.min(subCraft, buy) end
	return subCraft or buy
end

local function foreverCraftCost(itemID)
	local known = ns.Chains and ns.Chains.RecipeFor and ns.Chains.RecipeFor(itemID)
	if known then
		local total = 0
		for _, material in ipairs(known.materials) do
			local price = ns.Prices.Material(material.itemID)
			if not price then return nil end
			total = total + price * material.qty
		end
		return total / known.made
	end
	local candidates = foreverRecipesFor(itemID)
	if not candidates then return nil end
	local best
	for _, recipe in ipairs(candidates) do
		local working = { [itemID] = true }
		local total, ok = 0, true
		for _, material in ipairs(recipe.materials) do
			local price = foreverSubCost(material.itemID, recipe.professionID, 1, working)
			if not price then
				ok = false
				break
			end
			total = total + price * material.qty
		end
		if ok then
			local unit = total / recipe.made
			if not best or unit < best then best = unit end
		end
	end
	return best
end

local function ownedCount(id)
	return (C_Item.GetItemCount and C_Item.GetItemCount(id, true, false, true, true)) or 0
end

local function scannedEntryCost(entry, itemID)
	local schematic = entry.schematic
	local made = schematic and (((schematic.quantityMin or 1) + (schematic.quantityMax or 1)) / 2) or 1
	if made <= 0 then return nil end
	local othersFull, othersBuy, othersShort = 0, 0, false
	for _, other in ipairs(entry.others or {}) do
		local bestID, bestPrice
		local ownedAny = false
		for _, id in ipairs(other.itemIDs or {}) do
			if ownedCount(id) >= other.qty then ownedAny = true end
			local price = ns.Prices.Buy(id)
			if price and (not bestPrice or price < bestPrice) then bestID, bestPrice = id, price end
		end
		if not bestPrice then return nil end
		othersFull = othersFull + bestPrice * other.qty
		othersBuy = othersBuy + math.max(other.qty - ownedCount(bestID), 0) * bestPrice
		othersShort = othersShort or not ownedAny
	end

	local strategy = ns.db.craftStrategy
	local best
	for rank = 1, entry.maxRank or 1 do
		local output = entry.outputs and entry.outputs[rank]
		if output and output.itemID == itemID then
			for _, option in ipairs(entry.options or {}) do
				if (option.concentration or 0) == 0 and option.quality == rank then
					local full, buy, short, ok = othersFull, othersBuy, othersShort, true
					for _, slot in ipairs(entry.slots or {}) do
						local id = option.picks and option.picks[slot.slotIndex]
						local price = id and ns.Prices.Buy(id)
						if not price then
							ok = false
							break
						end
						local have = ownedCount(id)
						if have < slot.qty then short = true end
						full = full + price * slot.qty
						buy = buy + math.max(slot.qty - have, 0) * price
					end
					if ok then
						local better = not best
						if not better then
							if strategy == "owned" then
								if short ~= best.short then
									better = not short
								elseif buy ~= best.buy then
									better = buy < best.buy
								else
									better = full < best.full
								end
							else
								better = full < best.full
							end
						end
						if better then best = { full = full, buy = buy, short = short } end
					end
				end
			end
		end
	end
	return best and (best.full / made) or nil
end

local function scannedCraftCost(itemID)
	local best, coveredProf
	local current = ns.BestCrafts and ns.BestCrafts.Current and ns.BestCrafts.Current()
	if current and current.finished and current.recipes then
		coveredProf = current.professionID
		for _, entry in ipairs(current.recipes) do
			local cost = scannedEntryCost(entry, itemID)
			if cost and (not best or cost < best) then best = cost end
		end
	end
	local mine = ns.Scans and ns.Scans.Mine and ns.Scans.Mine()
	if mine then
		for _, entry in ipairs(mine) do
			if entry.professionID ~= coveredProf then
				local cost = scannedEntryCost(entry, itemID)
				if cost and (not best or cost < best) then best = cost end
			end
		end
	end
	return best
end

local function retailRecipesFor(itemID)
	local found = retailItemRecipes[itemID]
	if found ~= nil then return found end
	found = {}
	for professionID, packed in pairs(ns.RETAIL_ITEM_RECIPES or {}) do
		local pat = "%f[%d]" .. itemID .. ":(%d+)"
		for recipeID in packed:gmatch(pat) do
			found[#found + 1] = { recipeID = tonumber(recipeID), professionID = professionID }
		end
	end
	retailItemRecipes[itemID] = found
	return found
end

local function pickRetailSlotPrice(options, qty, isQuality, strategy, maxRank, targetRank)
	local function cheapest()
		local lowest
		for _, id in ipairs(options) do
			local price = ns.Prices.Buy(id)
			if price and (not lowest or price < lowest) then lowest = price end
		end
		return lowest
	end
	if not isQuality or strategy == "cheapest" then
		return cheapest()
	end
	local function highestChoice()
		if maxRank > 1 and targetRank then
			if targetRank >= maxRank then return ns.Prices.Buy(options[#options]) end
			if targetRank == 1 then return cheapest() end
			return ns.Prices.Buy(options[math.min(targetRank, #options)])
		end
		if maxRank > 1 and AllRecipes.Highest() then return ns.Prices.Buy(options[#options]) end
		return cheapest()
	end
	if strategy == "owned" then
		local topRank = maxRank > 1 and targetRank and targetRank >= maxRank
		local chosenIndex, chosenPrice
		for index, id in ipairs(options) do
			if ownedCount(id) >= qty then
				local price = ns.Prices.Buy(id)
				if price then
					if not chosenPrice then
						chosenIndex, chosenPrice = index, price
					elseif topRank and index > chosenIndex then
						chosenIndex, chosenPrice = index, price
					elseif not topRank and price < chosenPrice then
						chosenIndex, chosenPrice = index, price
					end
				end
			end
		end
		if chosenPrice then return chosenPrice end
	end
	return highestChoice()
end

local function retailFallbackCost(itemID)
	local strategy = ns.db.craftStrategy
	local best
	for _, entry in ipairs(retailRecipesFor(itemID)) do
		local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, entry.recipeID, false)
		if ok and schematic then
			local scroll = ns.Blizzard and ns.Blizzard.MakesScroll and ns.Blizzard.MakesScroll(entry.recipeID)
			if scroll then schematic = ns.Blizzard.ScrollSchematic(schematic) end
			if schematic and (scroll or schematic.recipeType == Enum.TradeskillRecipeType.Item) then
				local maxRank, targetRank = 0, nil
				if scroll and ns.ENCHANT_SCROLLS and ns.ENCHANT_SCROLLS[entry.recipeID] then
					local scrollsList = ns.ENCHANT_SCROLLS[entry.recipeID]
					maxRank = #scrollsList
					for idx, scrollItemID in ipairs(scrollsList) do
						if scrollItemID == itemID then
							targetRank = idx
							break
						end
					end
				else
					local okQ, qualityIDs = pcall(C_TradeSkillUI.GetQualitiesForRecipe, entry.recipeID)
					maxRank = okQ and qualityIDs and #qualityIDs or 0
					if maxRank > 1 and C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
						local okRank, rank = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, itemID)
						if okRank and rank then targetRank = rank end
					end
				end
				local total, hasMats, valid = 0, false, true
				for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
					if slot.required then
						local options = {}
						for _, reagent in ipairs(slot.reagents or {}) do
							if reagent.itemID then options[#options + 1] = reagent.itemID end
						end
						if #options > 0 then
							hasMats = true
							local isQuality = #options > 1 and ns.Blizzard and ns.Blizzard.IsQualitySlot
								and ns.Blizzard.IsQualitySlot(slot)
							local price = pickRetailSlotPrice(options, slot.quantityRequired or 1, isQuality, strategy,
								maxRank, targetRank)
							if not price then
								valid = false
								break
							end
							total = total + price * (slot.quantityRequired or 1)
						end
					end
				end
				local made = ((schematic.quantityMin or 1) + (schematic.quantityMax or 1)) / 2
				if hasMats and valid and made > 0 then
					local unit = total / made
					if not best or unit < best then best = unit end
				end
			end
		end
	end
	return best
end

local function craftCacheKey()
	local db = ns.db
	local ver = ns.Scans and ns.Scans.Version and ns.Scans.Version() or 0
	return table.concat({
		tostring(db.craftStrategy),
		tostring(db.vendorOnAH),
		tostring(db.provider),
		tostring(db.matSource),
		tostring(db.ahPrice),
		tostring(ver),
	}, "|")
end

-- What the materials to craft one of `itemID` cost in copper under the current
-- crafting strategy and price source, even on characters without the profession.
-- Nil when the item isn't craftable here or one of its materials has no price.
function AllRecipes.CraftCost(itemID)
	if not (ns.db and itemID) then return end
	local now = GetTime()
	local key = craftCacheKey()
	local cached = craftCosts[itemID]
	if not cached or cached.key ~= key or now >= cached.due then
		local cost
		if ns.QUALITY_CRAFTING then
			cost = scannedCraftCost(itemID) or retailFallbackCost(itemID)
		else
			cost = foreverCraftCost(itemID)
		end
		craftCosts[itemID] = {
			cost = cost or false,
			key = key,
			due = now + (cost and SCROLL_PRICED or SCROLL_UNPRICED),
		}
		cached = craftCosts[itemID]
	end
	return cached.cost or nil
end

-- Stops pricing and lets the recipes go: the window closed.
function AllRecipes.Release()
	run, rows, byItem, materialNames, materials = nil, nil, nil, nil, nil
end
