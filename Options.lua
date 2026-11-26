-- Craftonomics: the options window (Esc > Options > AddOns > Craftonomics). The
-- main page has what to craft and where prices come from; the rest sit on pages
-- under its "+": Panel, Shopping list, Auction house, Patron orders and Tooltips. WoW Forever
-- has no ranks, procs, concentration or crafting orders, so the options for
-- those (and the Patron orders page) aren't there.
local _, ns = ...

local Options = {}
ns.Options = Options

local format = string.format
local category
local settings = {} -- key -> the Settings object, for changes made outside the options

-- The game doesn't let addons open its settings during combat, so a request then waits for the fight to end.
local openAfterCombat = false
local combatWatch = CreateFrame("Frame")
combatWatch:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	openAfterCombat = false
	Options.Open()
end)

function Options.Open()
	if not category then return end
	if InCombatLockdown() then
		if not openAfterCombat then
			openAfterCombat = true
			combatWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
			print("|cffffd100Craftonomics:|r the options open when you leave combat.")
		end
		return
	end
	Settings.OpenToCategory(category:GetID())
end

local STRATEGY_KEYS = {
	craftStrategy = true, concentrationStrategy = true,
	patronMaterials = true, patronReach = true, concentrationFor = true,
	countPatronBags = true, countProcs = true, ahCut = true, vendorFloor = true,
	subtractExpectedDeposit = true, depositDuration = true, provider = true, matSource = true,
	saleSource = true, vendorOnAH = true,
}

-- Any change re-places and redraws the panel. Prices and the concentration
-- choice change the patron orders' picks too.
local function onChanged(key)
	if (not key or STRATEGY_KEYS[key]) and ns.Best and ns.Best.Forget then ns.Best.Forget() end
	ns.Planner.Reset()
	ns.Panel.Place()
	ns.Panel.Refresh()
	if key == "countPatronBags" and ns.Patron.Resort then ns.Patron.Resort() else ns.Patron.Redraw() end
	ns.BestCrafts.Reprice(true)
	if key == "bestFontSize" and ns.BestCraftsList and ns.BestCraftsList.ApplyFont then
		ns.BestCraftsList.ApplyFont()
	else
		ns.BestCraftsList.Refresh()
	end
	if ns.RecipeProfit then ns.RecipeProfit.Refresh() end
	ns.Minimap.Update()
	ns.ShoppingList.OptionsChanged()
end

-- Settings that change which TSM prices are saved for your alts: a change saves them again.
local RESAVE = { saveTSMPrices = true, saveItems = true, provider = true, matSource = true, saleSource = true }

-- Changes a setting from elsewhere (the Best crafts list), as the options would.
function Options.Set(key, value)
	if settings[key] then
		settings[key]:SetValue(value)
	else
		ns.db[key] = value
		if key == "provider" and value == "fresh" then
			ns.db.matSource, ns.db.saleSource = "dbminbuyout", "dbminbuyout"
		end
		onChanged(key)
	end
end

-- Refreshes calculations and lists after custom patron reward values change.
function Options.NotifyRewardsChanged()
	ns.Planner.Reset()
	ns.Panel.Refresh()
	if ns.Patron.Resort then ns.Patron.Resort() else ns.Patron.Redraw() end
end

function Options.Create()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("Craftonomics")
	local db = ns.db
	local quality = ns.QUALITY_CRAFTING -- false on WoW Forever
	-- The page settings go on: the main page, then each page under its "+".
	local page, pageLayout = category, layout
	-- "At the auction house, use": the setting that sets every part of the auction
	-- house at once (made on its page below), and whether it's doing so right now.
	local allSetting, settingAll = nil, false
	local AH_PART = {}
	for _, part in ipairs(ns.AH_PARTS) do AH_PART[part] = true end
	-- What that setting reads: the one all the parts agree on, or "custom".
	local function allParts()
		local first = db[ns.AH_PARTS[1]]
		for _, part in ipairs(ns.AH_PARTS) do
			if db[part] ~= first then return "custom" end
		end
		return (first == "own" or first == "auctionator") and first or "custom"
	end

	local function startPage(name)
		page, pageLayout = Settings.RegisterVerticalLayoutSubcategory(category, name)
	end

	local function header(name)
		pageLayout:AddInitializer(CreateSettingsListSectionHeaderInitializer(name))
	end

	local function setting(key, varType, name)
		local s = Settings.RegisterAddOnSetting(page, "CRAFTONOMICS_" .. key:upper(), key, db, varType, name, ns.DEFAULTS[key])
		s:SetValueChangedCallback(function()
			if key == "provider" and db.provider == "fresh" then
				if settings.matSource and db.matSource ~= "dbminbuyout" then settings.matSource:SetValue("dbminbuyout") end
				if settings.saleSource and db.saleSource ~= "dbminbuyout" then settings.saleSource:SetValue("dbminbuyout") end
			end
			onChanged(key)
			-- A part of the auction house changed on its own: the choice for all of them reads it again.
			if AH_PART[key] and allSetting and not settingAll then
				settingAll = true
				allSetting:SetValue(allParts(), true)
				settingAll = false
			end
			if key == "saveTSMPrices" and not db.saveTSMPrices then
				ns.SavedPrices.Forget()
			elseif RESAVE[key] then
				ns.SavedPrices.Save(true)
			end
		end)
		settings[key] = s
		return s
	end

	-- Like Settings.CreateCheckbox / CreateDropdown / CreateSlider, but on our own row
	-- templates (see Options.xml). On Blizzard's templates, a row that drew one of our
	-- settings is later reused for Blizzard's own, which then can't call protected functions:
	-- its Discord dropdown and button get blocked (ADDON_ACTION_FORBIDDEN on IsUserOAuthed).
	local function control(kind, s, options, tooltip)
		pageLayout:AddInitializer(Settings.CreateControlInitializer("CraftonomicsSettings" .. kind .. "Template", s,
			options, tooltip))
	end

	local function checkbox(key, name, tooltip)
		control("Checkbox", setting(key, Settings.VarType.Boolean, name), nil, tooltip)
	end

	-- `choices`: a list of { value, label }, or a function that returns one.
	local function dropdown(key, name, choices, tooltip)
		local function getOptions()
			local container = Settings.CreateControlTextContainer()
			local list = type(choices) == "function" and choices() or choices
			for _, choice in ipairs(list) do container:Add(choice[1], choice[2]) end
			return container:GetData()
		end
		control("Dropdown", setting(key, Settings.VarType.String, name), getOptions, tooltip)
	end

	local function button(name, text, onClick, tooltip)
		-- On our own row template too, and with no search tags: tags written from addon code
		-- taint the game's options search, and its Discord button then errors (IsUserOAuthed).
		pageLayout:AddInitializer(Settings.CreateElementInitializer("CraftonomicsSettingsButtonTemplate", {
			name = name,
			buttonText = text,
			buttonClick = onClick,
			tooltip = tooltip,
		}))
	end

	---------------------------------------------------------------------------
	-- The main page: what to craft and where prices come from
	---------------------------------------------------------------------------

	header("Crafting")
	local strategyChoices = {}
	local strategyTip = quality and "Which rank, and which materials, to craft on the crafting page:\n\n"
		or "Where the materials you're missing come from:\n\n"
	for _, strategy in ipairs(ns.STRATEGIES) do
		strategyChoices[#strategyChoices + 1] = { strategy[1], strategy[2] }
		strategyTip = strategyTip .. strategy[2] .. ": " .. strategy[4] .. "\n\n"
	end
	dropdown("craftStrategy", "Crafting strategy", strategyChoices, strategyTip .. (quality and
		"It picks the materials for Use Craftonomics Reagents and the panel's blue row, prices missing materials, " ..
		"decides what the shopping list buys, and ranks the Best crafts list. Patron orders keep their own rule: the " ..
		"cheapest materials that reach the order's minimum quality." or
		"It prices your materials, decides what the shopping list buys, and ranks the Best crafts list.") ..
		"\n\nAlso on the panel when a recipe is open, and at the bottom of the Best crafts list.")
	-- Procs only exist with Dragonflight's crafting.
	if quality then
		checkbox("countProcs", "Count procs in profits",
			"The Best crafts list ranks recipes by what they make on average with procs. The Patron tab shows and sorts orders by what they make on average with " ..
			"resourcefulness, the customer's materials included (the customer gets the item, so multicraft doesn't " ..
			"count). Your chances come from the " ..
			"game; how big a proc is, from your own crafts.\n\n" ..
			"The panel always shows both: the expected profit, and Without procs under it.\n\n" ..
			"Also in the Best crafts list's Filter menu.")
	end
	checkbox("listProfit", "Show profit/cost on the recipe list",
		"Every recipe you know shows its profit or crafting cost at the right of its row in the profession " ..
		"window's recipe list, using your crafting strategy and the top-left List toggle button.\n\n" ..
		"The first time you open a profession, the numbers take a moment to fill in.")
	local listMetricChoices = {
		{ "profit", "Profit" },
		{ "cost", "Crafting cost" },
	}
	if ns.SKILLUPS then
		listMetricChoices[#listMetricChoices + 1] = { "skillup", "Net skill-up cost" }
		listMetricChoices[#listMetricChoices + 1] = { "rawSkillup", "Raw skill-up cost" }
	end
	dropdown("listMetric", "Recipe list shows", listMetricChoices, "What to show on each recipe row in the profession window's recipe list.\n\n" ..
		"Profit: green makes gold, red loses it. Grey with a ? means a material has no price, so the profit is too high. " ..
		"Recipes whose item has no price show nothing.\n\n" ..
		"Crafting cost: what the materials for one craft cost, in white (grey with a ? when a material has no price). " ..
		"Helpful while leveling a profession, including enchants and recipes with no auction price.\n\n" ..
		(ns.SKILLUPS and (
			"Net skill-up cost: average net gold cost per skill point (materials minus resale or vendor value, divided by skill-up chance). " ..
			"Shows Free in green when crafting breaks even or profits; grey recipes are left blank.\n\n" ..
			"Raw skill-up cost: average raw material cost per skill point (materials divided by skill-up chance, ignoring resale value). " ..
			"Grey recipes are left blank.\n\n" ..
			"Left-click the top-left List button in the profession window to cycle modes, or right-click to pick directly.")
		or "Also toggled directly from the List: Profit / List: Cost button at the top left of the profession window."))

	header("Minimap button")
	checkbox("minimap", "Show minimap button",
		"Click: your profession window, on the Best crafts list of the profession you opened last. Right-click: a " ..
		"menu with your professions, the Ledger, the crafting strategy and these options. Hover: this session's total.\n\n" ..
		"Also in the minimap's addon menu, and /craftonomics minimap shows or hides it.")

	header("Prices")
	dropdown("provider", "Price addon", {
		{ "auto", "Automatic (TSM first)" },
		{ "tsm", "TradeSkillMaster only" },
		{ "auctionator", "Auctionator only" },
		{ "own", "Craftonomics' scan only" },
		{ "fresh", "Freshest prices" },
	}, "Where prices come from. Automatic uses TSM, falls back to Auctionator for items TSM has no price for, " ..
		"and to Craftonomics' own scan of the auction house for what neither prices. With neither installed, " ..
		"Craftonomics' scan prices everything.\n\n" ..
		"Freshest prices uses whichever is newest: TSM (its desktop app's last download), Auctionator's last " ..
		"scan, or Craftonomics' last full scan. An item the newest one didn't see takes the next newest's price. " ..
		"Picking Freshest prices sets both TSM price types below to Lowest auction right now so scans and TSM " ..
		"can stand in for each other; you can still change either one afterwards, and any other TSM price type " ..
		"prices as Automatic does. The footers say which one is in use and how old it is. " ..
		"Craftonomics' scan starts by itself at the auction house, at most once an hour, unless Auctionator does " ..
		"the pricing there (Price with, on the Auction house page). A scan made with TSM in the game doesn't " ..
		"count as a newer TSM price.\n\n" ..
		"This choice also controls where market metrics come from (Market Value, Historical Price, Trend, Lowest vs " ..
		"Market, Sale Rate, Sold per Day, and the Heatmap): picking Auctionator only or Craftonomics' scan only " ..
		"calculates them from that addon's scan history and your personal sale rate even when TSM is loaded.\n\n" ..
		"The scan runs from the Prices tab of Craftonomics' window at the auction house (/craftonomics prices).")
	checkbox("autoScan", "Scan when I open the auction house",
		"Craftonomics' own price scan starts by itself when you open the auction house.\n\n" ..
		"Only while your prices come from that scan (not from TSM or Auctionator), or with Freshest prices " ..
		"as the price addon, and at most once an hour. " ..
		"Chat says when it starts and when it's done.\n\n" ..
		"Off: you start it with Scan now on the Prices tab, or /craftonomics scan.")
	dropdown("matSource", "TSM price for materials", ns.TSM_SOURCES,
		"What you'd pay for materials. Market value smooths out spikes; lowest auction is what you'd pay right now. " ..
		"The lower of the two can show materials cheaper than you can buy them right now.")
	dropdown("saleSource", "TSM price for crafted items", ns.TSM_SOURCES,
		"What you'd get for the item you craft. The lower of market value and the lowest auction is the careful " ..
		"choice: you'd have to match a cheaper auction to sell now, and high listings that aren't selling don't count.")
	checkbox("scanReminder", "Remind me of old prices",
		"With prices from Auctionator or Craftonomics' scan: when the last scan is over a day old, a chat line reminds you when you open " ..
		"the auction house, and when it's over 3 days old, a notice over the Best crafts list when you open it (once a " ..
		"session). The panel's and the list's footers always say how old the scan is, in red once it's a day old.\n\n" ..
		"With TSM prices saved by another character: the same reminders, to log in on a character with TSM.")
	checkbox("vendorOnAH", "Buy vendor items on the auction house",
		"Materials a vendor sells (thread, flux, vials...) are priced at their auction house price and go on the " ..
		"shopping list.\n\nOff: they're priced at the vendor, and the shopping list says in chat to buy them there.\n\n" ..
		"When the auction house asks more than a vendor, the tooltips of what's missing say so, and so does chat " ..
		"when the shopping list gets it.\n\nAlso on the panel when a recipe is open.")
	checkbox("ahCut", format("Subtract auction house cut (%d%%)", ns.AH_CUT * 100),
		"The auction house keeps 5% of every sale.")
	checkbox("vendorFloor", "Use vendor price as minimum sale price",
		"When an item's auction house proceeds (after fees) are less than what a vendor pays for it, use the vendor " ..
		"sell price instead with no auction house fees.\n\nItems with no auction house price still show as unpriced.")
	checkbox("subtractExpectedDeposit", "Subtract expected AH deposit",
		"Subtracts expected lost auction house deposits from sale proceeds and profits, based on the item's sale rate.\n\n" ..
		"Because the final successful sale refunds its deposit, an item with a 33% sale rate loses about twice a " ..
		"single listing's deposit on average.\n\n" ..
		"Uses TSM's sale rate or your own personal sale rate (once you have at least 3 finished auctions). Skipped when " ..
		"no sale rate is available or when vendoring pays more.")
	dropdown("depositDuration", "Expected deposit duration", ns.DEPOSIT_DURATION_CHOICES,
		"Which auction duration to use when estimating expected auction house deposits for fees and Market details.\n\n" ..
		"Sell tab's duration uses the duration picked on Craftonomics' Sell tab (or the longest duration when none is picked).")

	header("TSM prices for alts")
	checkbox("saveTSMPrices", "Save TSM prices for alts",
		"Each time a character with TSM logs in, its prices are kept for your characters that don't load TSM. " ..
		"Turn TSM off on your crafting alts, and they still get TSM prices. The bottom of the panel says whose " ..
		"prices they are and how old.\n\n" ..
		"Gear prices only count on the realm they were saved on and its connected realms; other prices count " ..
		"on every realm. Prices over 2 weeks old aren't used.\n\n" ..
		"Turning it off deletes the saved prices, for all your characters.")
	local saveTip = "Which items' prices are saved:\n\n"
	for _, choice in ipairs(ns.SAVE_ITEMS_CHOICES) do
		saveTip = saveTip .. choice[2] .. ": " .. choice[3] .. "\n\n"
	end
	dropdown("saveItems", "Save prices for", ns.SAVE_ITEMS_CHOICES, saveTip ..
		"Items an alt has no price for get one the next time a character with TSM logs in.")

	---------------------------------------------------------------------------
	-- Panel
	---------------------------------------------------------------------------

	startPage("Panel")
	header("Where it shows")
	checkbox("crafting", "Show on the crafting page",
		"Profit for the recipe you have selected: sale price minus materials.")
	if quality then
		checkbox("orders", "Show on crafting orders",
			"Profit for the order you have open: commission minus the materials you supply.")
	end

	checkbox("panelAuto", "Open with the profession window",
		"The panel opens by itself when you pick a recipe. Off: it stays closed until you click the Craftonomics " ..
		"button at the top of the profession window. That button opens and closes the panel either way.\n\n" ..
		"Also at the bottom of the panel.")
	checkbox("disenchant", "Show disenchant value",
		"For a recipe that makes a weapon or armor: what disenchanting it gives on average, what that leaves after " ..
		"the materials, and a Disenchant advantage line when that's more than selling it makes.\n\n" ..
		"The value comes from TSM or Auctionator, whichever your prices come from. Without either, or when they " ..
		"can't price what the item disenchants into, the lines don't show.")
	checkbox("panelExpectedDeposit", "Show expected AH deposit",
		"Under Market details: an estimate of the auction house deposit lost across relistings before the item sells, " ..
		"using the Expected deposit duration set under Prices. Since the final sale refunds its deposit, an item with a " ..
		"33% sale rate loses about twice a single listing's deposit on average.\n\n" ..
		"Uses TSM's sale rate or your own personal sale rate (once you have at least 3 finished auctions).")

	header("Look")
	local scaleOptions = Settings.CreateSliderOptions(0.6, 1.5, 0.05)
	scaleOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
		return format("%d%%", value * 100 + 0.5)
	end)
	control("Slider", setting("scale", Settings.VarType.Number, "Panel size"), scaleOptions)
	-- WoW Forever always shows the two biggest coins (see Format.Money).
	if quality then
		dropdown("precision", "Show amounts down to", {
			{ "gold", "Gold (2,904g)" },
			{ "silver", "Silver (2,903g 83s)" },
			{ "copper", "Copper (2,903g 83s 45c)" },
		}, "Rounds every amount to this coin. Amounts smaller than one coin still show the next coin down.")
	end
	checkbox("locked", "Lock panel position", "Stop the panel from being dragged.")
	button("Panel position", "Reset", function()
		db.pos = nil
		ns.Panel.Place()
	end, "Put the panel back next to the profession window.")

	header("Best crafts window")
	local bestFontOptions = Settings.CreateSliderOptions(12, 20, 1)
	bestFontOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
		return format("%d pt", math.floor(value + 0.5))
	end)
	control("Slider", setting("bestFontSize", Settings.VarType.Number, "Best crafts text size"), bestFontOptions,
		"Text size inside the Best crafts window (from 12pt to 20pt). Also adjustable directly inside the window.")
	button("Best crafts window", "Reset", function()
		if ns.BestCraftsList and ns.BestCraftsList.ResetLayout then ns.BestCraftsList.ResetLayout() end
	end, "Reset the Best crafts window back to its default size and centered position.")

	if quality then
		header("Procs and session total")
		checkbox("procFx", "Animate procs",
			"When a craft procs, the bonus gold pops up over the Profit line and the panel flashes gold.")
		checkbox("procSound", "Coin sound on procs",
			"Play a coin sound when a craft procs multicraft or resourcefulness.")
	else
		header("Session total")
	end
	checkbox("showSession", "Show this session's total",
		"Adds up what every craft made since you logged in on this character. A /reload keeps it. Shown on the " ..
		(quality and "panel and at the bottom of the Patron tab's order list." or "panel."))
	button("Session total", "Reset", ns.Results.ResetSession, "Start the session total from zero.")

	---------------------------------------------------------------------------
	-- Shopping list
	---------------------------------------------------------------------------

	startPage("Shopping list")
	checkbox("shoppingButton", "Show Shopping list button",
		"A button under your materials for buying what you're short of" ..
		(quality and ", and the shopping buttons on the Patron tab: Add profitable, Add all and each order's cart "
			.. "button.\n\n" or ".\n\n") ..
		"Auctionator: a click opens a menu that adds what's missing for 1, 5, 10 or any number of crafts " ..
		"to an Auctionator shopping list.\n\n" ..
		"TSM: the same menu gives you a search to copy into TSM's Shopping tab, for exactly the " ..
		(quality and "ranks and " or "") .. "amounts you're missing.\n\n" ..
		"Craftonomics' own list: the same menu adds them to a list of its own. Its window opens beside the " ..
		"auction house, where a click on a material shows it with the amount you still need. " ..
		"It's used when Auctionator isn't installed, unless you pick the TSM search under " .. ns.LIST_ADDON_LABEL .. ".")
	checkbox("listPerCharacter", "One list per character",
		format("Each character gets its own list, named after it, like \"%s\".\n\n" ..
			"Can be combined with one list per profession: \"%s - Blacksmithing\".",
			UnitName("player") or "Name", UnitName("player") or "Name"))
	checkbox("listPerProfession", "One list per profession",
		format("Each profession gets its own list, like \"Blacksmithing\".\n\n" ..
			"Can be combined with one list per character. With neither, the list is \"%s\".", ns.SHOPPING_LIST))
	checkbox("checkOff", "Check off what you get",
		"Materials come off the shopping list, Auctionator's or Craftonomics' own, as you get them: bought, " ..
		"looted, from the mailbox or crafted. Chat says what came off, and when the list is done.\n\n" ..
		"Only what Craftonomics put on the list. Moving things between your bags and banks doesn't count.")
	button("Shopping list", "Clear", function() ns.Shopping.Clear() end,
		"Empties the shopping list. Ctrl-click the Shopping list button does the same.\n\n" ..
		"With one list per profession, this clears the list of the profession window that's open, " ..
		"or with none open, the lists of all this character's professions.")
	---------------------------------------------------------------------------
	-- Auction house
	---------------------------------------------------------------------------

	startPage("Auction house")
	-- Without Auctionator there's nothing to choose between: Craftonomics does
	-- everything, so only "Shop with" is left, and only when TSM is there to pick.
	local hasAuctionator = Auctionator ~= nil
	-- The Settings calls differ between game versions, and the parts below work without this one.
	if hasAuctionator then pcall(function()
		local master = Settings.RegisterProxySetting(page, "CRAFTONOMICS_AHALL", Settings.VarType.String, ns.AH_LABEL,
			ns.DEFAULTS.listAddon, allParts, function(value)
				if settingAll or value == "custom" then return end
				settingAll = true
				for _, part in ipairs(ns.AH_PARTS) do settings[part]:SetValue(value) end
				settingAll = false
			end)
		control("Dropdown", master, function()
			local container = Settings.CreateControlTextContainer()
			for _, choice in ipairs(ns.AH_CHOICES) do container:Add(choice[1], choice[2]) end
			if allParts() == "custom" then container:Add("custom", "Custom") end
			return container:GetData()
		end, "Auctionator or Craftonomics for everything at the auction house: shopping, selling, canceling " ..
			"and prices. Picking one sets all four choices below.\n\n" ..
			"Custom: the choices below aren't all the same.\n\n" ..
			"Craftonomics' window only has the tabs for what Craftonomics does. With Auctionator for everything, " ..
			"the window and its button on the auction house are gone.\n\n" ..
			"Auctionator's own tabs stay on the auction house whatever you pick.")
		allSetting = master
	end) end
	if hasAuctionator or ns.Prices.TSMInstalled() then
		dropdown("listAddon", ns.LIST_ADDON_LABEL, function()
			local list = {}
			for _, choice in ipairs(ns.LIST_ADDON_CHOICES) do
				local key, offered = choice[1], true
				if key == "auctionator" then
					offered = hasAuctionator
				elseif key == "tsm" then
					offered = ns.Prices.TSMInstalled()
				elseif not hasAuctionator and db.listAddon ~= "tsm" then
					-- Without Auctionator, a saved "Auctionator" means Craftonomics' list:
					-- this row keeps the saved value, so it comes back with Auctionator.
					key = db.listAddon
				end
				if offered then list[#list + 1] = { key, choice[2] } end
			end
			return list
		end,
			(hasAuctionator and "Auctionator: missing materials go to Auctionator's shopping list.\n\n" or "") ..
			"Craftonomics: they go to Craftonomics' own shopping list, on the Shopping list tab of its window.\n\n" ..
			(ns.Prices.TSMInstalled() and "TSM search to copy: they become a search to paste into TSM's Shopping tab.\n\n" or "") ..
			"You can also switch it at the bottom of the Shopping list menus.")
	end
	if hasAuctionator then
		dropdown("ahSell", "Sell with", ns.AH_CHOICES,
			"Craftonomics: its window has the Sell tab and opens by itself at the auction house. An item you put up " ..
			"for sale from your bags is picked there.\n\n" ..
			"Auctionator: no Sell tab, and Craftonomics leaves selling alone.")
		dropdown("ahCancel", "Cancel with", ns.AH_CHOICES,
			"Craftonomics: its window has the My auctions tab, with your undercut auctions and the button that " ..
			"cancels them.\n\n" ..
			"Auctionator: no My auctions tab.")
		dropdown("ahPrice", "Price with", ns.AH_CHOICES,
			"Craftonomics: its window has the Prices tab, and with Scan when I open the auction house on, its price " ..
			"scan starts by itself. It doesn't while your prices come from TSM.\n\n" ..
			"Auctionator: no Prices tab, and Craftonomics' scan doesn't start by itself. /craftonomics scan still " ..
			"starts one.\n\n" ..
			"It's also whose price is used when both have one. The other prices what the first doesn't.\n\n" ..
			"TSM's prices still come before both. Price addon on the main page can limit prices to one addon.")
	end
	header("Auction house window")
	checkbox("auctionWindow", "Open at the auction house",
		"Craftonomics' own window opens beside the auction house. There it has four tabs:\n\n" ..
		"Shopping list: what you still have to buy. A click on a material shows it at the auction house.\n\n" ..
		"Sell: what's in your bags that can be auctioned, your favorites first. Pick one, set the price, the " ..
		"amount and how long it lasts, and post it. The game's own sell page shows what it's listed for and " ..
		"is filled in with the same auction; a price, amount or duration you change there is changed here too.\n\n" ..
		"My auctions: your auctions, which of them are undercut, and a button that cancels those. The " ..
		"game's own Auctions tab opens beside it.\n\n" ..
		"Prices: when the auction house was last scanned for prices, and the button that scans it.\n\n" ..
		(hasAuctionator and "It only has the tabs for what Craftonomics does (see the choices above).\n\n" ..
			"It opens by itself beside the game's own auction house window, when Sell with is Craftonomics or " ..
			"Craftonomics' shopping list has something on it. "
			or "It opens by itself beside the game's own auction house window. ") ..
		"It doesn't open over another addon's " ..
		"auction house window.\n\n" ..
		"Away from the auction house it's only the shopping list.\n\n" ..
		"Off: it only opens from the minimap button's menu, the Shopping list menus, or /craftonomics shop. " ..
		"At the auction house, /craftonomics sell, auctions and prices open its other tabs.")
	dropdown("sellDefault", "Default posting time", ns.SELL_DEFAULT_CHOICES,
		"How long an auction lasts when you pick an item on the Sell tab. You can still change it there for " ..
		"the item you're posting.\n\n" ..
		"The last one you used: it stays on whatever you chose last.")

	---------------------------------------------------------------------------
	-- Patron orders
	---------------------------------------------------------------------------

	if quality then
		startPage("Patron orders")
		-- Every crafting order's own choices, separate from the crafting strategy.
		header("Crafting orders")
		for _, setting in ipairs({
			{ "patronMaterials", ns.PATRON_MATERIALS_TITLE, ns.PATRON_MATERIALS_CHOICES,
				"Which material qualities crafting orders use (patron, public, guild and personal), for their profit, " ..
				"Ready and what's missing, the shopping list and the Patron tab's craft button. The crafting page " ..
				"keeps the crafting strategy." },
			{ "patronReach", ns.PATRON_REACH_TITLE, ns.PATRON_REACH_CHOICES,
				"How an order with a minimum quality gets there, when both better materials and concentration would." },
		}) do
			local tip = setting[4] .. "\n\n"
			for _, choice in ipairs(setting[3]) do tip = tip .. choice[2] .. ": " .. choice[3] .. "\n\n" end
			dropdown(setting[1], setting[2], setting[3], tip .. "Also on the panel of an open order, and under the " ..
				"Patron tab's list.")
		end
		header("Patron tab")
		checkbox("patronList", "Show on the Patron tab",
			"The Patron tab's order list shows each order's profit or loss, its rewards and what materials you're " ..
			"missing, with buttons to shop for it and to start, craft and complete it. Buttons above the list shop for the profitable " ..
			"orders or all of them; under it, the concentration they use and the session total.\n\n" ..
			"Off: Blizzard's own columns (Patron Name, Commission, Reagents).")
		dropdown("concentrationFor", "Spend concentration on", ns.CONCENTRATION_CHOICES,
			"On the Patron tab, orders that only reach their minimum quality with concentration share what " ..
			"you have. They get it in this order until it runs out; the rest show their profit in grey and \"No concentration\".\n\n" ..
			"Most profit: the most gold per concentration point first.\n\n" ..
			"Knowledge first: orders that reward profession knowledge first, then the rest by profit.\n\n" ..
			"Don't use concentration: patron orders never spend it. Orders that need it to reach their minimum " ..
			"quality show \"No concentration\", get no cart or craft button, and Add profitable and Add all skip them; " ..
			"on their order form, Use Craftonomics Reagents leaves the materials alone. The crafting page isn't affected.\n\n" ..
			"You can also switch it with the gear at the bottom of the Patron tab.")
		local concentrationTip = ns.CONCENTRATION_STRATEGY_TIP .. "\n\n"
		for _, strategy in ipairs(ns.CONCENTRATION_STRATEGIES) do
			concentrationTip = concentrationTip .. strategy[2] .. ": " .. strategy[3] .. "\n\n"
		end
		dropdown("concentrationStrategy", ns.CONCENTRATION_STRATEGY_TITLE, ns.CONCENTRATION_STRATEGIES, concentrationTip ..
			"Gold per point counts the profit as the panel shows it, with procs when Count procs in profits is on.\n\n" ..
			"It picks the materials for Use Craftonomics Reagents on the order form and the crafting page. Patron orders " ..
			"don't use concentration while Spend concentration on is set to Don't use concentration. Also on the panel " ..
			"and in the gear at the bottom of the Patron tab.")
		checkbox("nextLosing", ns.NEXT_LOSING, ns.NEXT_LOSING_TIP ..
			"\n\nYou can also switch it with the gear at the bottom of the Patron tab.")
		header("Patron bags and Moxie")
		checkbox("countPatronBags", ns.COUNT_PATRON_BAGS, ns.COUNT_PATRON_BAGS_TIP ..
			"\n\nYou can also switch it with the gear at the bottom of the Patron tab.")
		button("Learned bag drops", "View...", function() Options.OpenBagDrops() end,
			"See every patron and 600-Moxie bag Craftonomics has learned from your opens, each item's drop percentage, " ..
			"average quantity and live auction house value, or reset a bag's history.\n\n" ..
			"Also in the Patron tab's gear menu, by right-clicking a bag or Moxie icon there, or with /craftonomics bags.")
	end

	---------------------------------------------------------------------------
	-- Tooltips
	---------------------------------------------------------------------------

	startPage("Tooltips")
	if quality then
		checkbox("rankTooltip", "Show your best rank",
			"On the tooltip of an item you can craft: the highest rank you can make it at with top-quality materials, " ..
			"using concentration if that reaches a higher rank.\n\n" ..
			"Updates each time you open your profession window.")
		dropdown("rankCharacters", "Show it for", {
			{ "all", "All your characters" },
			{ "current", "This character only" },
		}, "All your characters: one line for each character that knows the recipe, best rank first.\n\n" ..
			"A character shows up once you've opened its profession window, on any version of Craftonomics since 1.7.")
		checkbox("rankConcentration", "Show its concentration",
			"When the best rank needs concentration, add how much.")
	end
	button("Saved characters", "Forget...", ns.Ranks.OpenForgetMenu,
		"Pick a character you deleted, renamed or moved, so it no longer shows in Best crafts or tooltips.\n\n" ..
		"A character you still play comes back once you open its profession window again.")
	checkbox("tipVendorBuy", "Show vendor buy price",
		"On item tooltips: Vendor Buy, what a vendor charges for one. Only for items a vendor sells, once your " ..
		"price addon has seen one sell it" .. (quality and "." or " (common crafting reagents are always known)."))
	checkbox("tipVendorSell", "Show vendor sell price",
		"On item tooltips: Vendor Sell, what a vendor pays you for one. For a stack in your bags, hold Shift to " ..
		"also see what the whole stack sells for.")
	checkbox("tipAuction", "Show auction price",
		"On item tooltips: what the item sells for on the auction house, with the price you picked (the TSM " ..
		"price for crafted items on the main page, or Auctionator's). For a stack in your bags, hold Shift to " ..
		"also see what the whole stack sells for.\n\nNot on items you can't post, like soulbound ones.")
	checkbox("tipMarketValue", "Show market value",
		"On item tooltips: Market Value, the item's 14-day average price (with extreme outliers filtered out) from " ..
		"Auctionator's or Craftonomics' scan history, when your auction price isn't already TSM's. For a stack in " ..
		"your bags, hold Shift to also see the value of the whole stack.\n\n" ..
		"Needs at least 2 days of scans (or 1 recent day backed by older history). Not on items you can't post.")
	checkbox("tipCraftCost", "Show craft cost",
		"On item tooltips: Craft Cost, what the materials to craft one of the item cost, even on characters " ..
		"that don't have the profession. Follows your crafting strategy (" ..
		(quality and "Highest rank, Use what I own or Cheapest materials" or "Buy missing, Craft myself or Cheapest way") ..
		") and your Price addon. For a stack in your bags, hold Shift to also see the cost for the whole stack.\n\n" ..
		"Not shown when one of the item's materials has no price.")
	checkbox("tipCraftVsAH", "Show craft vs AH",
		"On item tooltips: Craft vs AH, crafting profit (after the 5% auction house cut when enabled) as a share " ..
		"of craft cost, with a hint:\n\n" ..
		"Craft +27%: crafting and selling on the AH makes 27% over craft cost.\n" ..
		"Buy -21%: crafting loses 21% compared to buying on the AH.\n" ..
		"Even: within 3% of breaking even.\n\n" ..
		"Not shown on items you can't post or when either price is missing.")
	checkbox("tipDeposit", "Show AH deposit",
		"On item tooltips: the auction house deposit for posting the item for " ..
		(quality and "12, 24 or 48" or "2, 8 or 24") .. " hours, for one, or for the whole " ..
		"stack in your bags while you hold Shift. You get it back when the item sells and lose it when it " ..
		"doesn't, so a deposit near the price means it's hardly worth posting.\n\nNot on items you can't post, like soulbound ones.")
	checkbox("tipExpectedDeposit", "Show expected AH deposit",
		"On item tooltips: Expected Deposit, an estimate of the auction house deposits lost across relistings " ..
		"before the item sells, for each duration. For example, at a 33% sale rate, selling takes about 3 " ..
		"listings on average, losing 2 deposits since the final sale refunds its deposit.\n\n" ..
		"Uses TSM's sale rate or your personal sale rate (once you have at least 3 finished auctions). Not on items you can't post.")
	checkbox("tipSaleRate", "Show sale rate",
		"On item tooltips: TSM Sale Rate with TSM, or Your Sale Rate from your own last 60 days of sold and " ..
		"expired auction mail (excluding cancellations)." ..
		(quality and ""
			or " With TSM on WoW Forever, it counts every ruleset of your region together (Normal, PvP...), not just yours.") ..
		" A high rate means it sells; a low one that most auctions expire.\n\nNot on items you can't post, like soulbound ones.")
	checkbox("tipTrend", "Show trend",
		"On item tooltips: Trend (or TSM Trend when using TSM), how far the item's 14-day market value" ..
		(quality and "" or " on your realm") ..
		" is from its 60-day historical price. -20% means it's 20% below it, +14% that it's 14% above.\n\n" ..
		"Uses TSM when loaded, or Auctionator's or Craftonomics' scan history (needs at least 3 days of scans).\n\n" ..
		"Not on items you can't post, like soulbound ones.")
	checkbox("tipLowest", "Show lowest vs market",
		"On item tooltips: Lowest vs Market (or TSM Lowest vs Market with TSM), how far the item's lowest auction" ..
		(quality and "" or " on your realm") .. " is from its market value, with a hint:\n\n" ..
		"Cheap -18%: the lowest auction is 18% below the market value.\n" ..
		"Expensive +12%: it's 12% above it.\n" ..
		"Even: within 3% of the market value.\n\n" ..
		"Uses TSM when loaded, or Auctionator's or Craftonomics' scan history. With Freshest prices and TSM, a " ..
		"newer scan's lowest auction shows as Lowest vs TSM Market.\n\n" ..
		"Only while someone has an auction up. Not on items you can't post, like soulbound ones.")
	checkbox("tipBestCraft", "Show best craft",
		"On the tooltip of a material: Best Craft, the most profitable recipe this character knows that takes it, " ..
		"with what one craft of it makes. It's the Best crafts list's profit, so it follows your crafting strategy.\n\n" ..
		"It follows chains: when what a recipe makes goes into another recipe that makes more, the line shows " ..
		"that one's profit, and the crafts on the way are listed under it, each set in further.\n\n" ..
		"A profession's recipes count once you've opened its profession window on this character. " ..
		"Recipes with no price for what they make, or for one of their materials, are left out. " ..
		"The line only shows when that recipe makes a profit.")
	checkbox("tipBestWeigh", "Weigh best craft by sale rate",
		"When the best craft is picked, a recipe's profit counts in full when what it makes has a " ..
		"sale rate of 70% or more, and for less below that, in proportion: at 35% it counts for half, at 7% for " ..
		"a tenth. So a craft that sells well can beat one that makes more but rarely sells.\n\n" ..
		"Uses TSM when loaded, or your personal sale rate once you have at least 3 finished auctions of the item. " ..
		"The Best Craft line still shows the craft's real profit. An item with no sale rate counts in " ..
		"full, and one with a sale rate of 0% is never the best craft.")
	checkbox("tipBestReturn", "Weigh best craft by return",
		"When the best craft is picked, a recipe's profit counts for more the higher its return (its profit as a " ..
		"share of what its materials cost), and for less the lower: as it is at a return of 25%, double at 50%, " ..
		"half at 12.5%. It never counts for more than four times, which a return of 100% reaches. So a craft that " ..
		"risks little gold for its profit can beat one that makes more from costly materials.\n\n" ..
		"The Best Craft line still shows the craft's real profit. With Weigh best craft by sale rate on as well, " ..
		"both count.")
	dropdown("tipBestShowReturn", "Best craft's return", {
		{ "shift", "While holding Shift" },
		{ "always", "Always" },
		{ "never", "Never" },
	}, "Under the Best Craft lines: the craft's return, its profit as a share of what its materials cost, like " ..
		"+25%.\n\n" ..
		"While holding Shift: in your bags it shows as you press Shift; anywhere else, hold Shift first, then " ..
		"hover the item.")
	dropdown("tipBestRate", "Best craft's sale rate", {
		{ "shift", "While holding Shift" },
		{ "always", "Always" },
		{ "never", "Never" },
	}, "Under the Best Craft and Recipe Profit lines: the sale rate of what the recipe makes (from TSM, or your own auction mail history).\n\n" ..
		"While holding Shift: in your bags it shows as you press Shift; anywhere else, hold Shift first, then " ..
		"hover the item.")
	checkbox("tipRecipe", "Show recipe profit",
		"On the tooltip of a recipe you can learn (a pattern, plan, schematic...): Recipe Profit, what one craft " ..
		"of the recipe it teaches makes, in green, or loses, in red, with what it makes under it. Whether or not " ..
		"you know the recipe.\n\n" ..
		"It's priced as the All recipes window prices it: the materials bought and what the craft makes sold" ..
		(quality and ", at the rank picked in that window" or "") .. ". " ..
		"Its return and sale rate show under it as Best craft's return and Best craft's sale rate say.\n\n" ..
		"Not on recipes with no price for what they make or for one of their materials, or that make an item " ..
		"that's bound when picked up" .. (quality and "." or ", or on enchanting formulas: an enchant makes nothing to sell."))
	checkbox("priceTooltip", "Show saved TSM prices",
		"On characters without TSM that use TSM prices saved by another character (see Save TSM prices for alts, " ..
		"on the main page): one line with the item's price, as Craftonomics prices it, and whose " ..
		"prices they are and how old.\n\nOnly items in those saved prices show it.")

	Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------
-- Learned bag drops window (patron payout bags & 600-Moxie surplus bags)
---------------------------------------------------------------------------

local BAG_WINDOW_NAME = "CraftonomicsBagDrops"
local BAG_ROW_HEIGHT = 26
local DEFAULT_BAG_ID = 246585
local bagWindow, selectedBagID

local BAG_ORDER = {
	246585, -- Artisan's Consortium Payout
	260534, 260536, 260537, 260538, 260540, 260541, 260542, 260545, -- crafting Surplus bags
	260539, 260543, 260544, -- gathering Surplus bags
}

local function bagDisplayName(bagID)
	return (C_Item.GetItemNameByID and C_Item.GetItemNameByID(bagID))
		or (C_Item.GetItemInfo and C_Item.GetItemInfo(bagID))
		or (ns.PATRON_BAGS and ns.PATRON_BAGS[bagID])
		or ("Item " .. bagID)
end

local function opensForBag(bagID)
	local entry = ns.db and ns.db.bagDrops and ns.db.bagDrops[bagID]
	return entry and entry.opens or 0
end

local function moxieCostForBag(bagID)
	for _, map in pairs(ns.MOXIE_BAGS or {}) do
		if map.bagID == bagID then return map.cost end
	end
end

local function sortedBagIDs()
	local seen, list = {}, {}
	local function add(bagID)
		if bagID and not seen[bagID] then
			seen[bagID] = true
			list[#list + 1] = bagID
		end
	end
	for _, id in ipairs(BAG_ORDER) do add(id) end
	for id in pairs(ns.db and ns.db.bagDrops or {}) do add(id) end
	return list
end

local function bagDropdownText(bagID)
	local opens = opensForBag(bagID)
	local name = bagDisplayName(bagID)
	return opens > 0 and format("%s (%d)", name, opens) or name
end

local function hasAnyBagDrops()
	for _, entry in pairs(ns.db and ns.db.bagDrops or {}) do
		if entry and entry.opens and entry.opens > 0 then return true end
	end
	return false
end

local function refreshBagWindow()
	local w = bagWindow
	if not (w and w:IsShown()) then return end
	selectedBagID = selectedBagID or DEFAULT_BAG_ID
	w.bagMenu:GenerateMenu()

	local est = ns.Model.BagEstimate(selectedBagID)
	local opens = est and est.opens or 0
	if est then
		local valueText = ns.Format.Money(est.value)
		w.summary:SetText(format("Opened: %d bag%s     Estimated value: %s",
			opens, opens == 1 and "" or "s", valueText))
		local moxieCost = moxieCostForBag(selectedBagID)
		if moxieCost and moxieCost > 0 then
			local perOne = est.value / moxieCost
			w.moxieLine:SetText(format("Per 1 Moxie (%d/bag): %s     Per 30 Moxie: %s",
				moxieCost, ns.Format.Money(perOne), ns.Format.Money(perOne * 30)))
			w.moxieLine:Show()
		else
			w.moxieLine:SetText(est.unpriced > 0
				and format("%d unpriced item%s skipped; updates automatically with your live AH prices.",
					est.unpriced, est.unpriced == 1 and "" or "s")
				or "Updates automatically with your live auction house prices.")
			w.moxieLine:Show()
		end
		w.empty:Hide()
		w.scrollBox:SetDataProvider(CreateDataProvider(est.breakdown), ScrollBoxConstants.RetainScrollPosition)
	else
		w.summary:SetText("Opened: 0 bags")
		local moxieCost = moxieCostForBag(selectedBagID)
		if moxieCost and moxieCost > 0 then
			w.moxieLine:SetText(format("Costs %d Artisan's Moxie per bag at the profession vendor.", moxieCost))
			w.moxieLine:Show()
		else
			w.moxieLine:Hide()
		end
		w.empty:Show()
		w.scrollBox:SetDataProvider(CreateDataProvider({}), ScrollBoxConstants.RetainScrollPosition)
	end

	w.resetOneBtn:SetEnabled(opens > 0)
	w.resetAllBtn:SetEnabled(hasAnyBagDrops())
end

function Options.RefreshBagDrops()
	refreshBagWindow()
end

StaticPopupDialogs.CRAFTONOMICS_RESET_BAG = {
	text = "Reset learned drops for %s?",
	button1 = "Reset",
	button2 = CANCEL,
	OnAccept = function(_, bagID)
		ns.Model.ResetBagDrops(bagID)
		Options.NotifyRewardsChanged()
		refreshBagWindow()
	end,
	showAlert = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

StaticPopupDialogs.CRAFTONOMICS_RESET_ALL_BAGS = {
	text = "Reset all learned patron and Moxie bag drops?",
	button1 = "Reset all",
	button2 = CANCEL,
	OnAccept = function()
		ns.Model.ResetBagDrops()
		Options.NotifyRewardsChanged()
		refreshBagWindow()
	end,
	showAlert = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function buildBagWindow()
	local w = CreateFrame("Frame", BAG_WINDOW_NAME, UIParent, "BasicFrameTemplateWithInset")
	w:SetSize(540, 460)
	w:SetPoint("CENTER")
	w:SetFrameStrata("DIALOG")
	w:SetToplevel(true)
	w:SetMovable(true)
	w:EnableMouse(true)
	w:RegisterForDrag("LeftButton")
	w:SetScript("OnDragStart", w.StartMoving)
	w:SetScript("OnDragStop", w.StopMovingOrSizing)
	w:SetClampedToScreen(true)
	tinsert(UISpecialFrames, BAG_WINDOW_NAME)
	w:Hide()

	local title = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -5)
	title:SetText("Craftonomics: learned bag drops")

	local bagMenu = CreateFrame("DropdownButton", nil, w, "WowStyle1DropdownTemplate")
	bagMenu:SetPoint("TOPLEFT", 16, -32)
	bagMenu:SetWidth(420)
	bagMenu:SetupMenu(function(_, root)
		for _, id in ipairs(sortedBagIDs()) do
			root:CreateRadio(bagDropdownText(id), function(v) return selectedBagID == v end, function(v)
				selectedBagID = v
				refreshBagWindow()
			end, id)
		end
	end)
	w.bagMenu = bagMenu

	local summary = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	summary:SetPoint("TOPLEFT", 18, -68)
	summary:SetPoint("TOPRIGHT", -18, -68)
	summary:SetJustifyH("LEFT")
	w.summary = summary

	local moxieLine = w:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	moxieLine:SetPoint("TOPLEFT", 18, -88)
	moxieLine:SetPoint("TOPRIGHT", -18, -88)
	moxieLine:SetJustifyH("LEFT")
	w.moxieLine = moxieLine

	local colItem = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	colItem:SetPoint("TOPLEFT", 20, -114)
	colItem:SetText("Item")

	local colVal = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	colVal:SetPoint("TOPRIGHT", -36, -114)
	colVal:SetWidth(104)
	colVal:SetJustifyH("RIGHT")
	colVal:SetText("Value / bag")

	local colAvg = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	colAvg:SetPoint("RIGHT", colVal, "LEFT", -8, 0)
	colAvg:SetWidth(72)
	colAvg:SetJustifyH("RIGHT")
	colAvg:SetText("Avg / bag")

	local colPct = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	colPct:SetPoint("RIGHT", colAvg, "LEFT", -8, 0)
	colPct:SetWidth(58)
	colPct:SetJustifyH("RIGHT")
	colPct:SetText("Drop %")

	local scrollBox = CreateFrame("Frame", nil, w, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", 14, -132)
	scrollBox:SetPoint("BOTTOMRIGHT", -32, 46)
	local scrollBar = CreateFrame("EventFrame", nil, w, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
	w.scrollBox = scrollBox

	local empty = w:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("TOPLEFT", scrollBox, "TOPLEFT", 8, -8)
	empty:SetPoint("RIGHT", scrollBox, "RIGHT", -8, 0)
	empty:SetJustifyH("LEFT")
	empty:SetText("No bags opened yet. Open this bag from your inventory and Craftonomics will record its drops automatically.")
	w.empty = empty

	local function drawBagRow(row, data)
		if not row.built then
			row.built = true
			row.icon = row:CreateTexture(nil, "ARTWORK")
			row.icon:SetSize(20, 20)
			row.icon:SetPoint("LEFT", 6, 0)
			row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

			row.valText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			row.valText:SetPoint("RIGHT", -4, 0)
			row.valText:SetWidth(104)
			row.valText:SetJustifyH("RIGHT")

			row.avgText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			row.avgText:SetPoint("RIGHT", row.valText, "LEFT", -8, 0)
			row.avgText:SetWidth(72)
			row.avgText:SetJustifyH("RIGHT")

			row.pctText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			row.pctText:SetPoint("RIGHT", row.avgText, "LEFT", -8, 0)
			row.pctText:SetWidth(58)
			row.pctText:SetJustifyH("RIGHT")

			row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
			row.nameText:SetPoint("RIGHT", row.pctText, "LEFT", -8, 0)
			row.nameText:SetJustifyH("LEFT")
			row.nameText:SetWordWrap(false)

			row:SetScript("OnEnter", function(self)
				if not self.dropData then return end
				local d = self.dropData
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(d.itemID)
				GameTooltip:AddLine(" ")
				local opens = opensForBag(selectedBagID)
				GameTooltip:AddLine(format("Dropped in %d of %d bags (%d total).", d.dropCount, opens, d.totalQty),
					1, 1, 1, true)
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave", GameTooltip_Hide)
		end

		row.dropData = data
		local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(data.itemID)
		row.icon:SetTexture(icon or 134400)

		local name = (ns.Format and ns.Format.ItemName and ns.Format.ItemName(data.itemID))
			or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(data.itemID))
			or (C_Item.GetItemInfo and C_Item.GetItemInfo(data.itemID))
		if name then
			row.nameText:SetText(ns.Format and ns.Format.RarityColored and ns.Format.RarityColored(data.itemID, name) or name)
		else
			row.nameText:SetText("Item " .. data.itemID)
			if Item and Item.CreateFromItemID then
				w.requested = w.requested or {}
				if not w.requested[data.itemID] then
					w.requested[data.itemID] = true
					local item = Item:CreateFromItemID(data.itemID)
					if item and not item:IsItemEmpty() then
						item:ContinueOnItemLoad(function()
							if w.redrawPending then return end
							w.redrawPending = true
							C_Timer.After(0.2, function()
								w.redrawPending = nil
								refreshBagWindow()
							end)
						end)
					end
				end
			end
		end

		row.pctText:SetText(format("%.0f%%", data.pct * 100))
		row.avgText:SetText(format("%.2f", data.avgQty))
		if data.bound then
			row.valText:SetText(ns.Color("muted", "not sellable"))
		elseif data.unitPrice then
			row.valText:SetText(ns.Format.Money(data.expected))
		else
			row.valText:SetText(ns.Color("warning", "no price"))
		end
	end

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(BAG_ROW_HEIGHT)
	view:SetElementInitializer("Frame", drawBagRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

	local resetOneBtn = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	resetOneBtn:SetSize(124, 22)
	resetOneBtn:SetPoint("BOTTOMLEFT", 16, 14)
	resetOneBtn:SetText("Reset this bag")
	resetOneBtn:SetScript("OnClick", function()
		if selectedBagID then
			StaticPopup_Show("CRAFTONOMICS_RESET_BAG", bagDisplayName(selectedBagID), nil, selectedBagID)
		end
	end)
	w.resetOneBtn = resetOneBtn

	local resetAllBtn = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	resetAllBtn:SetSize(96, 22)
	resetAllBtn:SetPoint("LEFT", resetOneBtn, "RIGHT", 8, 0)
	resetAllBtn:SetText("Reset all")
	resetAllBtn:SetScript("OnClick", function() StaticPopup_Show("CRAFTONOMICS_RESET_ALL_BAGS") end)
	w.resetAllBtn = resetAllBtn

	local closeBtn = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	closeBtn:SetSize(80, 22)
	closeBtn:SetPoint("BOTTOMRIGHT", -16, 14)
	closeBtn:SetText("Close")
	closeBtn:SetScript("OnClick", function() w:Hide() end)

	w:SetScript("OnShow", refreshBagWindow)
	bagWindow = w
	return w
end

-- Opens the learned patron & Moxie bag drops window (optionally selecting `bagID`).
function Options.OpenBagDrops(bagID)
	if bagID then
		selectedBagID = bagID
	elseif not selectedBagID or opensForBag(selectedBagID) == 0 then
		if opensForBag(DEFAULT_BAG_ID) > 0 then
			selectedBagID = DEFAULT_BAG_ID
		else
			selectedBagID = nil
			for _, id in ipairs(sortedBagIDs()) do
				if opensForBag(id) > 0 then
					selectedBagID = id
					break
				end
			end
			selectedBagID = selectedBagID or DEFAULT_BAG_ID
		end
	end
	local w = bagWindow or buildBagWindow()
	w:Show()
	w:Raise()
	refreshBagWindow()
end
