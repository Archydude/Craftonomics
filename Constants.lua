-- Craftonomics: values shared by every file. Change them here, not inline.
local _, ns = ...

-- The auction house keeps 5% of every sale.
ns.AH_CUT = 0.05
-- The item every caged battle pet is, on the auction house and in your bags.
ns.PET_CAGE_ITEM = 82800

-- Whether this game has Dragonflight's crafting: material and item qualities
-- (ranks), multicraft, resourcefulness and concentration. Retail does; WoW
-- Forever (game version 1.x) doesn't, so the crafting strategy and procs stay
-- out of sight there.
ns.QUALITY_CRAFTING = select(4, GetBuildInfo()) >= 100000

-- The picture for a recipe that makes no item (an enchant on WoW Forever), or
-- that the game gives none or its question mark: a scroll.
ns.SCROLL_ICON = "Interface\\Icons\\INV_Scroll_03"
local QUESTION_MARK_ICON = 134400

-- A recipe's picture as the game gave it, or the scroll in place of none or the
-- question mark.
function ns.RecipeIcon(icon)
	if not icon or icon == "" or icon == QUESTION_MARK_ICON then return ns.SCROLL_ICON end
	return icon
end

-- How long an auction can last, by the game's number for it: Retail's, or WoW Forever's.
ns.AUCTION_DURATIONS = ns.QUALITY_CRAFTING and { "12 hours", "24 hours", "48 hours" } or { "2 hours", "8 hours", "24 hours" }
-- Choices for how long the Sell tab starts a newly picked item on: the last one
-- you used, or always the same one (the game's number for it, as text).
ns.SELL_DEFAULT_CHOICES = { { "last", "The last one you used" } }
for index, text in ipairs(ns.AUCTION_DURATIONS) do
	ns.SELL_DEFAULT_CHOICES[#ns.SELL_DEFAULT_CHOICES + 1] = { tostring(index), text }
end
-- Choices for which auction duration estimates expected deposits when counting fees or showing Market details.
ns.DEPOSIT_DURATION_CHOICES = { { "sell", "Sell tab's duration" } }
for index, text in ipairs(ns.AUCTION_DURATIONS) do
	ns.DEPOSIT_DURATION_CHOICES[#ns.DEPOSIT_DURATION_CHOICES + 1] = { tostring(index), text }
end

-- Panel layout, in pixels before the panel's own scale.
ns.Layout = {
	WIDTH = 380,
	LINE_HEIGHT = 19,                  -- smallest row height
	PAD_TOP = 10,                      -- panel edge to the first row
	PAD_BOTTOM = 10,
	PAD_SIDE = 12,                     -- panel edge to the text
	GAP = 6,                           -- extra space that sets a row apart
	DIVIDER_GAP = 3,                   -- space above and below a divider line
	GEAR_SPACE = 40,                   -- room kept for the options and close buttons on the first row
	ICON_SIZE = 18,                    -- item, currency and quality icons in the text
	DEFAULT_POS = { x = 36, y = -60 }, -- from the profession window's top-right corner
	BORDER = { 0.66, 0.55, 0.32, 1 },  -- the panel's border: bronze
}

-- Text colors, as |c codes (alpha + RGB).
ns.Colors = {
	muted = "ff888888",     -- secondary text and notes
	profit = "ff33ff33",
	loss = "ffff4444",
	warning = "ffff6666",   -- "no price" and similar problems
	simulated = "ff66ccff", -- what-if qualities
	heading = "ffffd100",   -- the game's gold
	missing = "ffffaa33",
	good = "ff88ff88",
	secondSort = "ff66ccff", -- the header of the column a list sorts by second: light blue
	thirdSort = "ff88ff88",  -- and third: light green
	cheap = "ff33ff33",      -- tooltips' lowest auction well below market value
	expensive = "ff66ccff",  -- and well above it
}

function ns.Color(key, text)
	return "|c" .. ns.Colors[key] .. text .. "|r"
end

-- "profit" for zero or more, "loss" below zero.
function ns.AmountColor(amount)
	return amount >= 0 and "profit" or "loss"
end

-- Saved settings and their defaults.
ns.DEFAULTS = {
	crafting = true,      -- show on the normal crafting page
	panelAuto = true,     -- the panel opens by itself with the profession window; off: only from its button there
	orders = true,        -- show on crafting orders
	listProfit = true,    -- each recipe's profit/cost on its row of the game's recipe list
	listMetric = "profit", -- what each recipe row of the game's recipe list shows: "profit" | "cost" | "skillup" | "rawSkillup"
	disenchant = true,    -- the panel's disenchant value for weapons and armor
	panelExpectedDeposit = false, -- the panel's expected lost AH deposits based on sale rate
	marketOpen = true,    -- the panel's Market details are open (a click on their heading closes them)
	locked = false,
	scale = 1,
	precision = "silver", -- smallest coin shown: "copper" | "silver" | "gold"
	-- "auto" | "tsm" | "auctionator" | "own" (Craftonomics' scan) | "fresh" (TSM, Auctionator's scan or
	-- Craftonomics', whichever is newest; see Prices.lua)
	provider = "auto",
	matSource = "dbmarket",
	saleSource = "dbmarket",
	vendorOnAH = false,   -- materials vendors sell are bought on the auction house, not at a vendor
	saveTSMPrices = false, -- characters with TSM save its prices for the ones without it (see SavedPrices.lua)
	saveItems = "recipes", -- which items' prices they save (see ns.SAVE_ITEMS_CHOICES)
	ahCut = true,
	vendorFloor = true,              -- use vendor sell price as floor when it beats net AH proceeds
	subtractExpectedDeposit = false, -- subtract expected lost AH deposits from sale proceeds
	depositDuration = "sell",        -- duration used for expected deposit: "sell" | "1" | "2" | "3"
	procFx = true,        -- animate multicraft / resourcefulness procs
	procSound = true,     -- coin sound on procs
	showSession = true,   -- show the total of this session's crafts
	shoppingButton = true, -- the Shopping list button, and the shopping buttons on the Patron tab
	listAddon = "auctionator", -- materials go to: "auctionator" (the own list without it) | "tsm" | "own" (see Shopping.ListTarget)
	listPerCharacter = true,   -- a separate shopping list for each character
	listPerProfession = true,  -- and/or for each profession
	checkOff = true,           -- take materials off the shopping list as you get them
	-- Which of the two does the rest of the auction house: "auctionator" | "own" (see ns.UsesOwn)
	ahSell = "auctionator",    -- selling: "own" shows the Sell tab
	ahCancel = "auctionator",  -- canceling: "own" shows the My auctions tab
	ahPrice = "auctionator",   -- prices: whose come first with both (after TSM's); "own" shows the Prices tab and lets the scan start by itself
	auctionWindow = true,    -- Craftonomics' window opens by itself at the auction house (see ShoppingList.lua)
	auctionTab = "sell",       -- the tab it was last on at the auction house: "shop" | "sell" | "auctions" | "prices"
	sellDuration = 0,          -- how long auctions posted from the Sell tab last, by the game's number for it (0: not chosen yet, so the game's own choice)
	sellDefault = "last",      -- what a newly picked item starts on: "last" | "1" | "2" | "3" (see ns.SELL_DEFAULT_CHOICES)
	sellSort = "name",         -- the column the Sell tab's list is sorted by: "name" | "price" | "rate" | "amount"
	sellSortAscending = true,  -- and whether that's A to Z or lowest first
	patronList = true,    -- Craftonomics' columns, buttons and footer on the Patron tab's order list
	recipesExpansion = false,  -- Retail: the expansion the All recipes window lists, by the game's number (false: the newest)
	recipesRank = "highest",   -- Retail: recipes with ranks are priced at their "highest" rank with the best materials, or their "lowest" with the cheapest
	recipesProfitable = false, -- the All recipes window lists only the recipes that make gold
	recipesMinNet = false,     -- only the ones whose net profit is at least this, in copper (false: any),
	recipesRateMin = false,    -- and only the ones whose TSM sale rate is at least this, in percent (false: any),
	recipesRateMax = false,    -- and at most this
	recipesView = "list",      -- what the All recipes window shows: the "list", or a heatmap of "crafted" items or of "materials"
	patronSort = false,   -- the Patron tab sorted by profit: "desc" | "asc", or false for Blizzard's sort
	concentrationFor = "profit", -- patron orders that need concentration get it by: "profit" | "knowledge", or "none" of it
	concentrationStrategy = "cheapest", -- where concentration is spent, the qualities picked: "cheapest" | "least" concentration | most "gold" per point
	patronMaterials = "cheapest", -- patron orders' material qualities: "cheapest" | "owned" (see ns.PATRON_MATERIALS_CHOICES)
	patronReach = "materials",    -- reaching an order's minimum quality: "materials" | "concentration" first
	nextLosing = true,    -- the Patron tab's Next order button goes on to orders that lose gold
	countPatronBags = false, -- include learned live-AH value of patron bags and Moxie in order profits
	bestMaterials = false, -- "Use Craftonomics Reagents" on the order form and crafting page: put them in every order or recipe you open
	craftStrategy = ns.QUALITY_CRAFTING and "highest" or "buy", -- what the crafting page and Best crafts list craft (see ns.STRATEGIES)
	scanReminder = true,  -- remind you to scan the auction house when Auctionator's or Craftonomics' prices are old
	autoScan = true,      -- Craftonomics' own price scan starts by itself at the auction house (see PriceScan.lua)
	minimap = true,       -- the minimap button (its position is in minimapIcon, kept by LibDBIcon)
	countProcs = true,    -- multicraft and resourcefulness count in the Best crafts list
	rankTooltip = true,   -- best rank you can craft, on crafted items' tooltips
	priceTooltip = true,  -- saved TSM prices on item tooltips, on characters without TSM
	-- On item tooltips: what a vendor charges and pays, the auction price, the auction house deposit
	tipVendorBuy = true,
	tipVendorSell = true,
	tipAuction = true,
	tipMarketValue = true, -- item tooltips: 14-day Market Value when not already pricing from TSM
	tipCraftCost = true,
	tipCraftVsAH = true,  -- item tooltips: Craft Cost against auction price, with Craft or Buy
	tipDeposit = true,
	tipExpectedDeposit = false, -- item tooltips: expected lost AH deposits based on sale rate
	tipSaleRate = true,   -- item tooltips: TSM's sale rate
	tipTrend = true,      -- item tooltips: market value against historical price (TSM or scan history)
	tipLowest = true,     -- item tooltips: lowest auction against market value, with Cheap or Expensive
	tipBestCraft = true,  -- item tooltips: for a material, your most profitable recipe that takes it
	tipBestRate = "shift", -- that recipe's TSM sale rate under it: while holding "shift" | "always" | "never"
	tipBestWeigh = false, -- picking that recipe, a profit counts for less the worse what it makes sells (TSM sale rate under 70%)
	tipBestShowReturn = "shift", -- that recipe's return under it: while holding "shift" | "always" | "never"
	tipRecipe = true,     -- item tooltips: for a recipe item (pattern, plan...), what one craft of its recipe makes
	tipBestReturn = false, -- picking that recipe, a profit counts for more or less with its return on the materials' cost
	rankConcentration = true, -- add the concentration that rank takes
	rankCharacters = "all", -- whose ranks: "all" your characters | "current" one
	bestSort = "profit",  -- the Best crafts list's sort: "profit" | "plain" | "procs" | "cost" | "gold" | "perPoint" | "listed" | "sold" | "crafter" | "name"
	bestSortAscending = false,
	bestFontSize = 12,    -- Best crafts window text size in pt (12..20)
	bestAllCharacters = false, -- the Best crafts list shows your other characters' and professions' recipes
	bestProfitableOnly = false, -- the Best crafts list hides recipes that don't make a profit
	bestCanCraft = false, -- the Best crafts list hides recipes you're short of materials for
	bestShowIgnored = false, -- the Best crafts list shows the recipes you ignored, in grey
	ledgerRange = 30,     -- the Ledger window's days
}

-- Patron order rewards that give profession knowledge: itemID -> points each.
ns.KNOWLEDGE_ITEMS = {
	[246320] = 1, [246321] = 2, -- Alchemy (Flicker, Glimmer)
	[246322] = 1, [246323] = 2, -- Blacksmithing
	[246324] = 1, [246325] = 2, -- Enchanting
	[246326] = 1, [246327] = 2, -- Engineering
	[246328] = 1, [246329] = 2, -- Inscription
	[246330] = 1, [246331] = 2, -- Jewelcrafting
	[246332] = 1, [246333] = 2, -- Leatherworking
	[246334] = 1, [246335] = 2, -- Tailoring
}

-- Openable patron reward bags and 600-Moxie vendor bags whose drops Craftonomics learns as you open them.
ns.PATRON_BAGS = {
	[246585] = "Artisan's Consortium Payout",
	[260534] = "Master Alchemist's Surplus Reagents",
	[260536] = "Master Smith's Surplus Reagents",
	[260537] = "Master Enchanter's Surplus Reagents",
	[260538] = "Master Engineer's Surplus Reagents",
	[260539] = "Master Herbalist's Surplus Reagents",
	[260540] = "Master Scribe's Surplus Reagents",
	[260541] = "Master Jewelcrafter's Surplus Reagents",
	[260542] = "Master Leatherworker's Surplus Reagents",
	[260543] = "Master Miner's Surplus Reagents",
	[260544] = "Master Skinner's Surplus Reagents",
	[260545] = "Master Tailor's Surplus Reagents",
}
-- Each Midnight Artisan's Moxie currency buys its profession's 600-Moxie Surplus Reagents bag.
ns.MOXIE_BAG_COST = 600
ns.MOXIE_BAGS = {
	[3256] = { bagID = 260534, cost = ns.MOXIE_BAG_COST }, -- Alchemy
	[3257] = { bagID = 260536, cost = ns.MOXIE_BAG_COST }, -- Blacksmithing
	[3258] = { bagID = 260537, cost = ns.MOXIE_BAG_COST }, -- Enchanting
	[3259] = { bagID = 260538, cost = ns.MOXIE_BAG_COST }, -- Engineering
	[3260] = { bagID = 260539, cost = ns.MOXIE_BAG_COST }, -- Herbalism
	[3261] = { bagID = 260540, cost = ns.MOXIE_BAG_COST }, -- Inscription
	[3262] = { bagID = 260541, cost = ns.MOXIE_BAG_COST }, -- Jewelcrafting
	[3263] = { bagID = 260542, cost = ns.MOXIE_BAG_COST }, -- Leatherworking
	[3264] = { bagID = 260543, cost = ns.MOXIE_BAG_COST }, -- Mining
	[3265] = { bagID = 260544, cost = ns.MOXIE_BAG_COST }, -- Skinning
	[3266] = { bagID = 260545, cost = ns.MOXIE_BAG_COST }, -- Tailoring
}
ns.COUNT_PATRON_BAGS = "Count estimated value of patron bags and Moxie"
ns.COUNT_PATRON_BAGS_TIP = "Include the learned live auction house value of Artisan's Consortium Payout bags and " ..
	"Artisan's Moxie (valued from your opened 600-Moxie Surplus Reagents bags divided by 600) in patron order " ..
	"profits, sorting, Add profitable, Next order and concentration picks.\n\n" ..
	"Off (default): patron order profits only count real gold and directly sellable rewards, while hovering a " ..
	"bag or Moxie still shows its learned drop breakdown."

-- The concentration strategy: which material qualities are picked where
-- concentration is spent. On the panel, in the options and in the Patron tab's
-- gear menu. { key, label, tooltip }.
ns.CONCENTRATION_STRATEGY_TITLE = "Concentration strategy"
ns.CONCENTRATION_STRATEGY_TIP = "Within the target rank, which material qualities are picked where concentration is spent: on orders that " ..
	"only reach their minimum quality with concentration, and on the crafting page with Concentrate on (except with Cheapest materials)."
ns.CONCENTRATION_STRATEGIES = {
	{ "cheapest", "Lowest material cost (default)", "The cheapest material qualities for that rank, whatever concentration they take." },
	{ "least", "Least concentration", "The material qualities that take the least concentration, and the " ..
		"cheapest of those. The materials cost more, but your concentration lasts for more crafts." },
	{ "gold", "Most gold per point", "The material qualities that earn the most gold for each concentration point. " ..
		"Cheaper materials win when what they save is worth the extra concentration." },
}

-- One of those: the one for `key`, or the one in use.
function ns.ConcentrationStrategy(key)
	key = key or ns.db.concentrationStrategy
	for _, strategy in ipairs(ns.CONCENTRATION_STRATEGIES) do
		if strategy[1] == key then return strategy end
	end
	return ns.CONCENTRATION_STRATEGIES[1]
end

-- What the concentration strategy picks by, when not just the cheapest: "least", "gold", or nil.
function ns.OptimizesFor()
	local key = ns.ConcentrationStrategy()[1]
	return key ~= "cheapest" and key or nil
end

-- The "Next order: include orders that lose gold" option, in the Patron tab's gear menu and the options.
ns.NEXT_LOSING = "Next order: include orders that lose gold"
ns.NEXT_LOSING_TIP = "Once the orders that make a profit are done, the Next order button goes on to the ones you " ..
	"have everything for that lose gold, smallest loss first: for their knowledge or other rewards.\n\n" ..
	"Off: it stops after the profitable ones. Their own hammer still does any order."

-- Choices for which patron orders get your concentration first.
ns.CONCENTRATION_CHOICES = {
	{ "profit", "Most profit (default)" },
	{ "knowledge", "Knowledge first" },
	{ "none", "Don't use concentration" },
}

-- Crafting orders' own choices (every order, the Patron tab's included): which
-- material qualities they use, and how they reach their minimum quality.
-- { key, label, tooltip }.
ns.PATRON_MATERIALS_TITLE = "Order materials"
ns.PATRON_MATERIALS_CHOICES = {
	{ "cheapest", "Cheapest (default)", "The cheapest qualities that reach the order's minimum quality, whether you own " ..
		"them or buy them." },
	{ "owned", "Use what I own", "Qualities you own first. Only what you're short of is bought, at the cheapest " ..
		"quality that still reaches the minimum." },
}
ns.PATRON_REACH_TITLE = "Reach the minimum with"
ns.PATRON_REACH_CHOICES = {
	{ "materials", "Better materials (default)", "Higher-rank materials first; concentration only when no " ..
		"materials reach the minimum." },
	{ "concentration", "Concentration", "Concentration with lower-rank materials first; better materials only when " ..
		"you're out of concentration, or Spend concentration on is set to Don't use concentration." },
}

-- A choice's name without "(default)".
function ns.ChoiceName(choice)
	return (choice[2]:gsub(" %(default%)$", ""))
end

-- A dropdown menu for one of those settings: a radio for each choice, with its
-- explanation as its tooltip. Picking one changes it everywhere it shows.
function ns.ChoiceMenu(key, title, choices)
	return function(_, root)
		root:CreateTitle(title)
		for _, choice in ipairs(choices) do
			local radio = root:CreateRadio(choice[2], function(value) return ns.db[key] == value end,
				function(value) ns.Options.Set(key, value) end, choice[1])
			radio:SetTooltip(function(tooltip)
				GameTooltip_SetTitle(tooltip, choice[2])
				tooltip:AddLine(choice[3], 1, 1, 1, true)
			end)
		end
	end
end

-- What such a dropdown shows for its choice: the name, after `prefix` if given.
function ns.ChoiceText(choices, prefix)
	return function(selection)
		for _, choice in ipairs(choices) do
			if choice[1] == selection.data then return (prefix or "") .. ns.ChoiceName(choice) end
		end
	end
end

-- Crafting strategies: which rank and materials the crafting page and the Best
-- crafts list craft. key, name, short name, and what it does. WoW Forever has no
-- ranks, so there they say where missing materials come from (see Chains.lua).
ns.STRATEGIES = ns.QUALITY_CRAFTING and {
	{ "highest", "Highest rank", "Highest rank",
		"The highest rank you can make, using the cheapest materials that reach it (or your concentration strategy while concentrating)." },
	{ "owned", "Use what I own", "What I own",
		"The highest rank you have every material for. Short for all of them: the highest rank you can make, spending the least gold on what you're missing. While concentrating, your concentration strategy only picks among mixes with the same out-of-pocket cost. The Best crafts list only shows what you can craft now." },
	{ "cheapest", "Cheapest materials", "Cheapest",
		"The cheapest materials overall, whatever rank they make (ignores the concentration strategy). For skill-ups, first crafts and knowledge." },
} or {
	{ "buy", "Buy missing", "Buy missing",
		"Materials you're missing are bought at their auction house price." },
	{ "craft", "Craft myself", "Craft myself",
		"Materials you know the recipe for are crafted, down to what has to be bought: they cost what their own " ..
		"materials cost, and the shopping list buys those instead. Recipes from all this character's professions " ..
		"count, once you've opened that profession's Best crafts list." },
	{ "mix", "Cheapest way", "Cheapest way",
		"Each material you know the recipe for is crafted or bought, whichever costs less, down to what has to be " ..
		"bought. The shopping list buys what that takes. Recipes from all this character's professions count, once " ..
		"you've opened that profession's Best crafts list." },
}

-- The current crafting strategy's entry in ns.STRATEGIES.
function ns.Strategy()
	for _, strategy in ipairs(ns.STRATEGIES) do
		if strategy[1] == ns.db.craftStrategy then return strategy end
	end
	return ns.STRATEGIES[1]
end

-- The crafting strategy dropdowns' menu (under the Best crafts list and on the
-- panel): one choice per strategy, with what it does in its tooltip.
function ns.StrategyMenu(_, root)
	for _, strategy in ipairs(ns.STRATEGIES) do
		local key = strategy[1]
		local radio = root:CreateRadio(strategy[2], function() return ns.db.craftStrategy == key end,
			function() ns.Options.Set("craftStrategy", key) end, key)
		radio:SetTooltip(function(tip)
			GameTooltip_SetTitle(tip, strategy[2])
			GameTooltip_AddNormalLine(tip, strategy[4])
		end)
	end
end

-- What a strategy dropdown shows for the picked strategy: its short name.
function ns.StrategyText(selection)
	for _, strategy in ipairs(ns.STRATEGIES) do
		if strategy[1] == selection.data then return strategy[3] end
	end
end

-- What you use at the auction house, Auctionator or Craftonomics, is one choice
-- for each part of it: these settings, in the options' order. The first (where
-- missing materials go) can also be a TSM search. AH_LABEL is the option that
-- sets them all at once.
ns.AH_LABEL = "At the auction house, use"
ns.AH_PARTS = { "listAddon", "ahSell", "ahCancel", "ahPrice" }
ns.AH_CHOICES = {
	{ "auctionator", "Auctionator" },
	{ "own", "Craftonomics" },
}

-- Whether Craftonomics does that part of the auction house itself: it's the one
-- picked, or Auctionator isn't installed to do it.
function ns.UsesOwn(part)
	return ns.db[part] == "own" or not Auctionator
end

-- Choices for where missing materials go: Auctionator's list, a TSM search, or
-- Craftonomics' own list. The option's name is also the title over these choices
-- in the Shopping list menus.
ns.LIST_ADDON_LABEL = "Shop with"
ns.LIST_ADDON_CHOICES = {
	{ "auctionator", "Auctionator" },
	{ "tsm", "TSM search to copy" },
	{ "own", "Craftonomics" },
}

-- The shopping list the missing materials button adds to, when the list isn't
-- named after the character or profession.
ns.SHOPPING_LIST = "Crafting"

-- Which items' TSM prices are saved for your alts: key, name, and what it saves.
ns.SAVE_ITEMS_CHOICES = {
	{ "recipes", "Your recipes", "The materials and crafts of your characters' recipes, once you've opened their " ..
		"Best crafts list. The smallest save." },
	{ "crafting", "All crafting items", "Your recipes, plus every material, reagent, consumable, gem, enchant, " ..
		"recipe and decor item TSM has auction prices for." },
	{ "all", "Everything TSM has", "Your recipes, plus every item TSM has auction prices for on your realm, gear " ..
		"at each item level included. The biggest save." },
}

-- Kinds of item "All crafting items" saves, by item class. Housing is decor,
-- on game versions that have it.
ns.CRAFTING_CLASSES = {}
for _, class in ipairs({ "Consumable", "Gem", "Reagent", "Tradegoods", "ItemEnhancement", "Recipe", "Housing" }) do
	local classID = Enum.ItemClass[class]
	if classID then ns.CRAFTING_CLASSES[classID] = true end
end

-- The lower of market value and the lowest auction, as a TSM price.
ns.TSM_LOWER = "min(dbmarket, dbminbuyout)"

-- TSM price types offered in the options.
ns.TSM_SOURCES = {
	{ "dbmarket", "Market value (recommended)" },
	{ "dbminbuyout", "Lowest auction right now" },
	{ ns.TSM_LOWER, "Lower of market and lowest" }, -- short: the closed dropdown cuts long names
	{ "dbhistorical", "Historical price" },
	{ "dbregionmarketavg", "Region market average" },
}

-- A TSM price as footers and tooltips name it: its own name, shorter for the
-- lower of two.
function ns.TSMSourceText(source)
	if source == ns.TSM_LOWER then return "lower of dbmarket, dbminbuyout" end
	return source
end

-- WoW Forever: what disenchanting gives. By what the item is (armor or weapon)
-- and its quality, rows of { lowest item level, highest, then one
-- { chance in percent, fewest, most, itemID } for each material it can give }.
-- Armor mostly gives dust and weapons mostly essences; rare items give a shard
-- and epic ones several, or a crystal.
if not ns.QUALITY_CRAFTING then
	local STRANGE, SOUL, VISION, DREAM, ILLUSION = 10940, 11083, 11137, 11176, 16204 -- dusts
	local LESSER_MAGIC, GREATER_MAGIC, LESSER_ASTRAL, GREATER_ASTRAL = 10938, 10939, 10998, 11082 -- essences
	local LESSER_MYSTIC, GREATER_MYSTIC, LESSER_NETHER, GREATER_NETHER = 11134, 11135, 11174, 11175
	local LESSER_ETERNAL, GREATER_ETERNAL = 16202, 16203
	local SMALL_GLIMMERING, LARGE_GLIMMERING, SMALL_GLOWING, LARGE_GLOWING = 10978, 11084, 11138, 11139 -- shards
	local SMALL_RADIANT, LARGE_RADIANT, SMALL_BRILLIANT, LARGE_BRILLIANT = 11177, 11178, 14343, 14344
	local NEXUS = 20725 -- crystal

	-- Uncommon items by item level: the dust and the essence with how many of each,
	-- and the shard (one, when there is one).
	local UNCOMMON = {
		{ 5, 15, { STRANGE, 1, 2 }, { LESSER_MAGIC, 1, 2 } },
		{ 16, 20, { STRANGE, 2, 3 }, { GREATER_MAGIC, 1, 2 }, SMALL_GLIMMERING },
		{ 21, 25, { STRANGE, 4, 6 }, { LESSER_ASTRAL, 1, 2 }, SMALL_GLIMMERING },
		{ 26, 30, { SOUL, 1, 2 }, { GREATER_ASTRAL, 1, 2 }, LARGE_GLIMMERING },
		{ 31, 35, { SOUL, 2, 5 }, { LESSER_MYSTIC, 1, 2 }, SMALL_GLOWING },
		{ 36, 40, { VISION, 1, 2 }, { GREATER_MYSTIC, 1, 2 }, LARGE_GLOWING },
		{ 41, 45, { VISION, 2, 5 }, { LESSER_NETHER, 1, 2 }, SMALL_RADIANT },
		{ 46, 50, { DREAM, 1, 2 }, { GREATER_NETHER, 1, 2 }, LARGE_RADIANT },
		{ 51, 55, { DREAM, 2, 5 }, { LESSER_ETERNAL, 1, 2 }, SMALL_BRILLIANT },
		{ 56, 60, { ILLUSION, 1, 2 }, { GREATER_ETERNAL, 1, 2 }, LARGE_BRILLIANT },
		{ 61, 65, { ILLUSION, 2, 5 }, { GREATER_ETERNAL, 2, 3 }, LARGE_BRILLIANT },
	}
	-- The shard's chance: 10% at item levels 21 to 25, 5% elsewhere. What's left goes
	-- to the dust and the essence: most of it to the dust for armor (to the essence
	-- for a weapon), the other getting 20%, or 15% next to that 10%.
	local function uncommon(mostlyDust)
		local rows = {}
		for index, tier in ipairs(UNCOMMON) do
			local low, high, dust, essence, shard = unpack(tier)
			local shardChance = shard and (low == 21 and 10 or 5) or 0
			local less = shardChance == 10 and 15 or 20
			local more = 100 - shardChance - less
			local row = { low, high,
				{ mostlyDust and more or less, dust[2], dust[3], dust[1] },
				{ mostlyDust and less or more, essence[2], essence[3], essence[1] } }
			if shard then row[5] = { shardChance, 1, 1, shard } end
			rows[index] = row
		end
		return rows
	end

	local RARE = {
		{ 5, 25, { 100, 1, 1, SMALL_GLIMMERING } },
		{ 26, 30, { 100, 1, 1, LARGE_GLIMMERING } },
		{ 31, 35, { 100, 1, 1, SMALL_GLOWING } },
		{ 36, 40, { 100, 1, 1, LARGE_GLOWING } },
		{ 41, 45, { 100, 1, 1, SMALL_RADIANT } },
		{ 46, 50, { 100, 1, 1, LARGE_RADIANT } },
		{ 51, 55, { 100, 1, 1, SMALL_BRILLIANT } },
		{ 56, 65, { 99.5, 1, 1, LARGE_BRILLIANT }, { 0.5, 1, 1, NEXUS } },
	}
	local EPIC = {
		{ 40, 45, { 100, 2, 4, SMALL_RADIANT } },
		{ 46, 50, { 100, 2, 4, LARGE_RADIANT } },
		{ 51, 55, { 100, 2, 4, SMALL_BRILLIANT } },
		{ 56, 60, { 100, 1, 1, NEXUS } },
		{ 61, 65, { 100, 1, 2, NEXUS } },
	}
	local quality = Enum.ItemQuality
	ns.DISENCHANTS = {
		[Enum.ItemClass.Armor] = { [quality.Uncommon] = uncommon(true), [quality.Rare] = RARE, [quality.Epic] = EPIC },
		[Enum.ItemClass.Weapon] = { [quality.Uncommon] = uncommon(false), [quality.Rare] = RARE, [quality.Epic] = EPIC },
	}
end
