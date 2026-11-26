-- Craftonomics: the Best crafts window. A "Best crafts" tab on the profession
-- window (or clicking the minimap button / /craftonomics best) opens a movable,
-- resizable window styled like All recipes: every recipe of the profession
-- shown (or all your characters), most profitable first, with adjustable text
-- size. Draws the rows BestCrafts.lua works out.
local _, ns = ...

local BestCraftsList = {}
ns.BestCraftsList = BestCraftsList

local Color, Money, Item = ns.Color, ns.Format.Money, ns.Format.Item
local format = string.format

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 1040, 640
local MIN_WIDTH, MIN_HEIGHT = 760, 420
local MAX_WIDTH, MAX_HEIGHT = 1600, 1000
local SIDE = 12             -- window edge to its content
local TOP_BAR = 30          -- window top to Search, Filter, and Text size controls
local INSET_TOP = 62        -- window top to the list's box
local INSET_PAD = 8         -- that box's edge to what's in it
local SCROLLBAR_ROOM = 20   -- scroll bar space inside the box
local FOOTER_BAR = 32       -- room at the bottom for status, All characters, Strategy, and resize grip
local CELL_GAP = 10         -- between columns
local ICON_X_BASE = 20      -- row's left edge to the item icon at 12pt; the pin goes in that room
local ACTIONS_SIZE = 18
local ACTIONS_REACH_LEFT, ACTIONS_REACH_RIGHT = 8, 4 -- how far past the row button a click still lands on it
local ACTIONS_DOT = 3       -- the row button's three dots: each dot's size,
local ACTIONS_DOT_GAP = 5   -- and how far apart they are
local EMPTY_WIDTH = 460     -- the line an empty list shows: its width,
local EMPTY_LIFT = 30       -- and how far above the middle it sits
local TAG_GAP = 4           -- item name to its rank and other icons
local LEDGER_SIZE = 20      -- the Ledger button on the panel
local LEDGER_RIGHT = 46     -- panel's right edge to the button (room for its gear and close button)
local LEDGER_TOP = 5        -- panel's top edge to the button
local LEDGER_GAP = 6        -- the button to the panel's title
local TAB_TEXT_ROOM = 40    -- the Best crafts tab's width beyond its label
local TAB_GAP = 2           -- the tab before it to the Best crafts tab
local SIDE_TAB_GAP = 2      -- Forever: the side tab above it to the Best crafts side tab, as Blizzard's
local LEDGER_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local SIDE_TAB_ICON = "Interface\\AddOns\\Craftonomics\\Media\\logo" -- the addon's logo
local RESIZE_UP = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up"
local RESIZE_HIGHLIGHT = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight"
local RESIZE_DOWN = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down"
local OPEN_TRIES, OPEN_RETRY = 20, 0.1 -- from an order: waiting for the recipes to show
local REOPEN_TRIES = 40     -- after a profession switch: waiting for its recipes (OPEN_RETRY apart)
local FILTER_WIDTH = 90
local TEXT_SIZE_WIDTH = 114
local STRATEGY_WIDTH = 136  -- the crafting strategy dropdown at the bottom
local STRATEGY_LABEL = "Strategy:"
local REFRESH_DELAY = 0.2   -- redraws are batched this long
local STALE_DAYS = 3        -- Auctionator counts this old or older show in grey
local STALE_SCAN_DAYS = 7   -- other characters' saved scans this old or older show in the warning color
local MIN_FONT, MAX_FONT = 12, 20
local FONT_SIZES = { 12, 13, 14, 15, 16, 18, 20 }

-- Columns right of the item name, right to left: key, width, header, sort key,
-- needsTSM: true shows it only with TSM, false only without, and allCharacters:
-- the same for the All characters view, needsProcs: only while procs count, and
-- goldWidth: its width when amounts show in whole gold, and foreverWidth: on WoW
-- Forever, whose amounts are two coins at most (4g 12s), leaving the names room.
-- forever: true shows it only on WoW Forever, false only off it (Per skill-up
-- takes Gold/day's place there). saleRate: false hides it where TSM's sale rate
-- takes its place (WoW Forever with TSM, see Prices.ShowsSaleRate). needsRate:
-- when SaleRateSource() exists (TSM or personal sale rate).
-- The demand column is TSM's Sells/day, or without TSM, You sold.
-- Of the columns that can show, you pick which do (right-click a header, see
-- addColumnChoices): offByDefault ones start hidden, and fixed ones always show.
local COLUMNS = {
	{ key = "actions", width = ACTIONS_SIZE },
	{ key = "sold", width = 64, header = "You sold", sort = "sold", needsTSM = false },
	{ key = "perDay", width = 64, header = "Sells/day", sort = "perDay", needsTSM = true, saleRate = false },
	{ key = "saleRate", width = 64, header = "Sale rate", sort = "saleRate", needsRate = true },
	-- Starts hidden off WoW Forever, where the list has more columns to fit.
	{ key = "trend", width = 56, header = "Trend", sort = "trend", needsTrend = true, offByDefault = ns.QUALITY_CRAFTING },
	{ key = "listed", width = 46, header = "Listed", sort = "listed", saleRate = false },
	{ key = "gold", width = 74, header = "Gold/day", sort = "gold", forever = false },
	{ key = "perPoint", width = 96, goldWidth = 56, header = "Per point", sort = "perPoint", forever = false,
		offByDefault = true },
	{ key = "skillup", width = 84, header = "Per skill-up", sort = "skillup", forever = true },
	{ key = "chance", width = 56, header = "Chance", sort = "chance", forever = true },
	{ key = "cost", width = 112, goldWidth = 70, foreverWidth = 76, header = "Cost", sort = "cost" },
	-- Starts hidden off WoW Forever, like Trend.
	{ key = "returns", width = 56, header = "Return", sort = "returns", offByDefault = ns.QUALITY_CRAFTING },
	{ key = "profit", width = 112, goldWidth = 70, foreverWidth = 76, header = "Profit", sort = "profit", fixed = true },
	{ key = "procs", width = 96, goldWidth = 56, header = "Procs", sort = "procs", needsProcs = true },
	{ key = "plain", width = 112, goldWidth = 64, header = "No procs", sort = "plain", needsProcs = true },
	{ key = "crafter", width = 64, header = "Crafter", sort = "crafter", allCharacters = true, fixed = true },
}
local HEADER_TIPS = {
	name = "Click to sort by name.",
	crafter = "Which of your characters makes it. A character shows up here after opening Best crafts once.",
	profit = "What one craft makes after the 5% auction house cut, at the rank and with the materials your crafting "
		.. "strategy picks. A rank is never priced above a better one.\n\nWith Count procs in profits on (Filter menu), "
		.. "it's Expected: what a craft makes on average with procs.",
	gold = "Roughly what this recipe could make in a day: the profit on each item times how many sell per day. For "
		.. "comparing recipes, not a promise: with TSM it counts sales across your whole region, and you'd only get a "
		.. "share of them. Without TSM, it counts your own recent sales. Recipes that lose gold or haven't sold show -.",
	plain = "What one craft makes with no procs at all: the part that doesn't depend on luck.",
	procs = "What multicraft and resourcefulness add to a craft on average. Any one craft can get all of it or none.",
	cost = "What the materials for one craft cost, at the rank and with the materials your crafting strategy picks.",
	returns = "The profit as a share of what the materials cost: +25% means every 100 gold of materials makes 25 "
		.. "gold. A low return leaves little room: a small change in prices turns the craft into a loss. Recipes "
		.. "without a profit or a material cost show -.",
	listed = "How many were up for sale in the last auction scan.",
	perDay = "How many sell per day across your region, on average, from TSM.",
	saleRate = "Of the auctions posted for this item, the share that sells: a high rate means it sells, a "
		.. "low one that most expire. "
		.. (ns.QUALITY_CRAFTING and "With TSM, it counts your whole region; without TSM, it uses your own last 60 days of sold and expired auction mail (excluding cancellations)."
			or "With TSM on WoW Forever, it counts every ruleset of your region together (Normal, PvP...); without TSM, it uses your own last 60 days of sold and expired auction mail (excluding cancellations)."),
	trend = "How far the item's market value" .. (ns.QUALITY_CRAFTING and "" or " on your realm")
		.. " is from its historical price: -20% means it's "
		.. "20% below it, +14% that it's 14% above. Uses TSM when loaded, or Auctionator's or Craftonomics' scan history.",
	sold = format("How many your characters sold on the auction house in the last %d days, from the auction "
		.. "house's mail. Counts sales from when you first opened your mailbox with this version.", ns.Sales.DAYS),
	perPoint = "What each concentration point earns with this recipe: how much more a craft makes when you "
		.. "concentrate to reach the next rank, divided by the concentration that takes. For seeing where your "
		.. "concentration is worth the most. The concentration strategy picks the materials for it. Recipes where "
		.. "concentrating adds nothing show -.",
}
-- WoW Forever has no ranks or procs to explain.
if not ns.QUALITY_CRAFTING then
	HEADER_TIPS.profit = "What one craft makes after the 5% auction house cut."
	HEADER_TIPS.cost = "What the materials for one craft cost, with your crafting strategy."
	HEADER_TIPS.skillup = "What one skill point costs with this recipe at your skill: the materials, minus what the "
		.. "item is worth back (its auction price after the cut, or what a vendor pays if that's more), divided by "
		.. "the chance a craft gives a skill-up.\n\nFree: the recipe makes gold, so its skill points cost nothing. "
		.. "Sorted cheapest first, the free ones first, surest skill-up first.\n\nGrey recipes give no skill-ups and show -."
	HEADER_TIPS.chance = "The chance a craft gives a skill-up at your skill, in the recipe's color. Orange recipes always "
		.. "give one; yellow and green ones less often the closer they get to grey. Grey recipes give none and show -."
end

---------------------------------------------------------------------------
-- Fonts and responsive window metrics (minimum 12pt everywhere)
---------------------------------------------------------------------------

local function makeFont(name, base)
	local font = CreateFont(name)
	font:CopyFontObject(base)
	return font
end

local rowFont = makeFont("CraftonomicsBestCraftsRowFont", GameFontHighlight)
local headerFont = makeFont("CraftonomicsBestCraftsHeaderFont", GameFontHighlight)

local function fontSize()
	local raw = ns.db and tonumber(ns.db.bestFontSize) or MIN_FONT
	return math.max(MIN_FONT, math.min(MAX_FONT, math.floor(raw + 0.5)))
end

local function metrics()
	local fs = fontSize()
	local scale = fs / MIN_FONT
	local iconPx = math.max(14, math.min(24, math.floor(fs * 1.3 + 0.5)))
	return {
		size = fs,
		scale = scale,
		rowHeight = math.max(24, math.floor(fs * 1.9 + 0.5)),
		iconSize = math.max(18, math.min(28, math.floor(fs * 1.6 + 0.5))),
		headerHeight = math.max(22, math.floor(fs * 1.7 + 0.5)),
		iconX = math.max(ICON_X_BASE, math.floor(ICON_X_BASE * scale + 0.5)),
		inlineIcon = iconPx,
	}
end

local appliedFontSize

local function applyFontObject(fontObj, fs)
	local path, _, flags = GameFontHighlight:GetFont()
	if path then fontObj:SetFont(path, fs, flags or "") end
end

-- What the Profit column shows: with procs counted, the expected profit.
local function shownProfit(row)
	if ns.db.countProcs then return row.expected end
	return row.profit
end

-- The shown profit as a share of what the materials cost, for the Return column.
-- Nil (which sorts last) without a profit or a cost.
local function returnOf(row)
	return ns.Format.ReturnShare(shownProfit(row), row.cost)
end

-- How many of the item sell per day: across your region with TSM, or your own
-- average without it. Nil when neither says.
local function demandOf(row)
	if row.soldPerDay then return row.soldPerDay end
	if row.itemName and not ns.Prices.HasTSM() then
		return row.sold / math.max(ns.Sales.DaysCounted(), 1)
	end
end

-- What the recipe could make in a day, for the Gold/day column. Nil (which sorts
-- last) when there's no profit or no sales number to go on.
local function goldPerDay(row)
	local profit, demand = shownProfit(row), demandOf(row)
	if not (profit and demand) then return end
	local schematic = row.entry.schematic
	local perItem = profit / (((schematic.quantityMin or 1) + (schematic.quantityMax or 1)) / 2)
	if perItem <= 0 or demand <= 0 then return end
	return perItem * demand
end

-- The row's character, by key ("Name-Realm"): a saved one, or this one.
local function crafterKey(row)
	local _, myKey = ns.Ranks.Me()
	return row.entry.character or myKey or ""
end

-- How each sort key reads a row's value; nil values always go last.
local SORT_VALUES = {
	profit = shownProfit,
	gold = goldPerDay,
	crafter = crafterKey,
	plain = function(row) return row.profit end,
	procs = function(row) return row.profit and row.procs and row.procs.total end,
	cost = function(row) return row.cost end,
	returns = returnOf,
	listed = function(row) return row.listed end,
	sold = function(row) return row.itemName and row.sold or nil end,
	perDay = function(row) return row.soldPerDay end,
	saleRate = function(row) return row.saleRate end,
	trend = function(row) return row.trend end,
	-- Free skill points first, the surest of those first (as -chance), then the cheapest.
	skillup = function(row)
		local s = row.skillup
		if not (s and s.cost) then return end
		if s.cost <= 0 then return -s.chance end
		return s.cost
	end,
	chance = function(row) return row.skillup and row.skillup.chance end,
	perPoint = function(row) return row.concentration and row.concentration.extra / row.concentration.points end,
}
-- A pinned row's mark: the first atlas the game has, or else the word.
local PIN_ATLASES = { "Waypoint-MapPin-Tracked", "Waypoint-MapPin-Untracked" }
local FIRST_CRAFT_ATLAS = "professions_icon_firsttimecraft"
-- The sorted column's arrow: the auction house's, or the older one.
local SORT_ARROW_ATLAS = "auctionhouse-ui-sortarrow"
local SORT_ARROW_FILE = "Interface\\Buttons\\UI-SortArrow"
local SORT_ARROW_SIZE = 10
local MAX_SORTS = 2        -- how many columns the list sorts by at once

local list, listTab, ledgerButton, scrollBox, scrollView, headerBar, status
local strategyDropdown, textSizeDropdown, charactersButton, emptyText
local headers = {}
local refreshQueued = false

local function signedMoney(amount)
	return Color(ns.AmountColor(amount), (amount > 0 and "+" or "") .. Money(amount))
end

-- "+1,250" and the gold icon, in whole gold, to fit the Gold/day column; under 1
-- gold, the usual amount.
local function dailyText(amount)
	local gold = math.floor(math.abs(amount) / 10000 + 0.5)
	if gold < 1 then return signedMoney(amount) end
	return Color(ns.AmountColor(amount), (amount > 0 and "+" or "-") .. GetMoneyString(gold * 10000, true))
end

local function pinMarkup(px)
	for _, atlas in ipairs(PIN_ATLASES) do
		if C_Texture.GetAtlasInfo(atlas) then return CreateAtlasMarkup(atlas, px, px) end
	end
	return Color("heading", "pinned")
end

local function firstCraftMarkup(px)
	if C_Texture.GetAtlasInfo(FIRST_CRAFT_ATLAS) then return CreateAtlasMarkup(FIRST_CRAFT_ATLAS, px, px) end
	return Color("good", "new")
end

local function cooldownMarkup(px)
	return format("|TInterface\\Icons\\INV_Misc_PocketWatch_01:%d|t", px)
end

-- "0.4" below 10 a day, "25" or "1,250" from there.
local function perDayText(perDay)
	if perDay < 10 then return format("%.1f", perDay) end
	return BreakUpLargeNumbers(math.floor(perDay + 0.5))
end

-- "3 h", "25 min".
local function timeText(seconds)
	if seconds >= 3600 then return format("%d h", math.ceil(seconds / 3600)) end
	return format("%d min", math.ceil(seconds / 60))
end

---------------------------------------------------------------------------
-- Which rows, in which order
---------------------------------------------------------------------------

-- Each recipe's material names, lowercase, one per line, for the search: entry ->
-- text. Kept once every name is known: the game loads an item's name the first
-- time it's asked for, and the list is drawn again when one arrives.
local materialNames = setmetatable({}, { __mode = "k" })

local function materialsText(entry)
	local text = materialNames[entry]
	if text then return text end
	local names, complete = {}, true
	local function add(itemID)
		local name = C_Item.GetItemNameByID(itemID)
		if name then
			names[#names + 1] = name:lower()
		else
			complete = false
			C_Item.RequestLoadItemDataByID(itemID)
		end
	end
	for _, slot in ipairs(entry.slots or {}) do
		for _, option in ipairs(slot.options) do add(option.itemID) end
	end
	for _, other in ipairs(entry.others or {}) do
		for _, itemID in ipairs(other.itemIDs) do add(itemID) end
	end
	text = table.concat(names, "\n")
	if complete then materialNames[entry] = text end
	return text
end

-- The search finds item names, the materials recipes use (Copper Bar), and in
-- All characters, characters too.
local function matches(row, search)
	if search == "" or row.sortName:find(search, 1, true) then return true end
	if materialsText(row.entry):find(search, 1, true) then return true end
	return ns.db.bestAllCharacters and crafterKey(row):lower():find(search, 1, true) ~= nil
end

-- Whether a column can show, with these addons and in this view.
local function columnAvailable(column)
	if column.forever ~= nil and column.forever == ns.QUALITY_CRAFTING then return false end
	if column.saleRate ~= nil and column.saleRate ~= ns.Prices.ShowsSaleRate() then return false end
	if column.needsRate and not ns.Prices.HasSaleRate() then return false end
	if column.needsTrend and not ns.Prices.HasTrend() then return false end
	if column.needsProcs and not ns.db.countProcs then return false end
	if column.needsTSM ~= nil and column.needsTSM ~= ns.Prices.HasTSM() then return false end
	return column.allCharacters == nil or column.allCharacters == ns.db.bestAllCharacters
end

-- Whether you want a column: your pick, or else whether it shows by default.
local function columnChosen(column)
	if column.fixed or not column.header then return true end
	local choice = ns.db.bestColumns[column.key]
	if choice ~= nil then return choice end
	return not column.offByDefault
end

-- Whether a column shows: it can, and you want it.
local function columnShown(column)
	return columnAvailable(column) and columnChosen(column)
end

-- A saved sort key as the list can sort by it now, or nil when its column is
-- gone or hidden in this view.
local function usableKey(key)
	if key == "sold" or key == "perDay" then key = ns.Prices.HasTSM() and "perDay" or "sold" end
	if key ~= "name" and not SORT_VALUES[key] then return end
	for _, column in ipairs(COLUMNS) do
		if column.sort == key and not columnShown(column) then return end
	end
	return key
end

local function sortKey()
	return usableKey(ns.db.bestSort) or "profit"
end

-- Every column the list sorts by, in order: the one you clicked, then the ones
-- you shift-clicked ({ key, ascending } each). Leaves out the ones that can't
-- sort now.
local function sortChain()
	local chain = { { key = sortKey(), ascending = ns.db.bestSortAscending } }
	local seen = { [chain[1].key] = true }
	for _, more in ipairs(ns.db.bestSortMore) do
		local key = usableKey(more.key)
		if key and not seen[key] and #chain < MAX_SORTS then
			seen[key] = true
			chain[#chain + 1] = { key = key, ascending = more.ascending }
		end
	end
	return chain
end

local function isPinned(row) return ns.db.bestPinned[row.entry.recipeID] == true end

-- Pinned rows first. Then sorted by the chosen columns, the first one that tells
-- two rows apart deciding; rows without a value for a column go last on it either
-- way. Ties go by profit, then name.
local function sortRows(rows)
	local function nameOf(row) return row.sortName end
	local chain = sortChain()
	for _, sort in ipairs(chain) do sort.valueOf = SORT_VALUES[sort.key] or nameOf end
	table.sort(rows, function(a, b)
		local aPinned, bPinned = isPinned(a), isPinned(b)
		if aPinned ~= bPinned then return aPinned end
		for _, sort in ipairs(chain) do
			local av, bv = sort.valueOf(a), sort.valueOf(b)
			if (av == nil) ~= (bv == nil) then return av ~= nil end
			if av ~= bv and av ~= nil then
				if sort.ascending then return av < bv end
				return av > bv
			end
		end
		local ap, bp = shownProfit(a), shownProfit(b)
		if (ap == nil) ~= (bp == nil) then return ap ~= nil end
		if ap ~= bp and ap then return ap > bp end
		return nameOf(a) < nameOf(b)
	end)
end

local allRows = {} -- every row before filtering, for the filter menu's counts

-- The rows to show, sorted. Also how many more would show if "Use what I own"
-- didn't leave out the recipes you're short of materials for.
local function visibleRows()
	local search = list.Search:GetText():lower()
	local shown, short = {}, 0
	allRows = ns.BestCrafts.Rows()
	for _, row in ipairs(allRows) do
		if matches(row, search) and not ns.db.bestHidden[row.group]
			and not (ns.db.bestIgnored[row.entry.recipeID] and not ns.db.bestShowIgnored)
			and not (ns.db.bestProfitableOnly and not ((shownProfit(row) or 0) > 0)) then
			if (ns.db.craftStrategy == "owned" or ns.db.bestCanCraft) and row.short then
				short = short + 1
			else
				shown[#shown + 1] = row
			end
		end
	end
	sortRows(shown)
	return shown, short
end

-- What an empty list says, or nil while it has rows, none to filter, or prices
-- are still being worked out. `short`: see visibleRows.
local function emptyNote(count, short)
	if count > 0 or #allRows == 0 or ns.BestCrafts.Progress() then return end
	if short > 0 then
		if ns.db.bestCanCraft and ns.db.craftStrategy ~= "owned" then
			return "Nothing you can craft with what you own.\n\nTurn off Can craft now in the Filter menu to see the rest."
		end
		return format("Nothing you can craft with what you own.\n\nThe %s strategy only lists recipes you have every "
			.. "material for. Pick another strategy below to see the rest.", ns.Strategy()[3])
	end
	return "No recipes match the search and the filter."
end

---------------------------------------------------------------------------
-- The row tooltip
---------------------------------------------------------------------------

local function addLine(tip, text) tip:AddLine(text, 1, 1, 1, true) end
local function addPair(tip, left, right) tip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1) end

local function rankIcon(row, rank)
	return ns.Blizzard.ItemQualityMarkup(row.entry.recipeID, rank) or ("rank " .. rank)
end

local function listedText(count, age)
	if not count then return Color("muted", "-") end
	local text = BreakUpLargeNumbers(count)
	if age and age > 0 then
		local seen = Color("muted", ", " .. ns.Prices.AgeText(age))
		return (age >= STALE_DAYS and Color("muted", text) or text) .. seen
	end
	return text
end

-- "Skill data from 3 days ago", for the tooltip of a recipe from a saved scan.
local function scanAgeText(entry)
	local days = math.floor((time() - entry.scanned) / 86400)
	return Color(days >= STALE_SCAN_DAYS and "warning" or "muted", "Skill data from " .. ns.Prices.AgeText(days))
end

local function rowTooltip(tip, row)
	local entry = row.entry
	tip:SetText(entry.name or "?")
	if ns.db.bestAllCharacters then
		addPair(tip, "Crafter", ns.Ranks.CharacterName(crafterKey(row)))
		if entry.scanned then addLine(tip, scanAgeText(entry)) end
	end
	local schematic = entry.schematic
	local qtyMin, qtyMax = schematic.quantityMin or 1, schematic.quantityMax or 1
	if row.output then
		addLine(tip, format("Makes %s %s", qtyMin == qtyMax and (qtyMin .. "x") or (qtyMin .. "-" .. qtyMax .. "x"), row.output.link))
	end

	if row.profit then
		local sellText = ns.db.ahCut and format("Sells for (after %d%% AH cut)", ns.AH_CUT * 100) or "Sells for"
		addPair(tip, sellText, Money(row.sale))
		if row.cappedBy then
			tip:AddLine(ns.Model.CappedNote(entry.recipeID, row.cappedBy, row.listedPrice), 0.53, 0.53, 0.53, true)
		end
	elseif row.quality and entry.maxRank > 1 then
		addPair(tip, "Sells for", Color("warning", "no price at " .. rankIcon(row, row.quality)))
	elseif row.output then
		addPair(tip, "Sells for", Color("warning", "no auction price"))
	else
		addPair(tip, "Sells for", Color("muted", "nothing to sell"))
	end

	tip:AddLine(" ")
	tip:AddLine("Materials", 1, 0.82, 0)
	for _, material in ipairs(ns.BestCrafts.Materials(row)) do
		addPair(tip, Item(material.itemID, material.qty),
			material.price and Money(material.price * material.qty) or Color("warning", "no price"))
	end
	addPair(tip, "Materials cost", Money(-row.cost))
	if row.profit then
		addPair(tip, row.profit >= 0 and "Profit" or "Loss", signedMoney(row.profit))
	end
	local procs = row.procs
	if row.expected and procs.total > 0 then
		addPair(tip, "Expected with procs", signedMoney(row.expected))
		if procs.chances.multicraft > 0 then
			tip:AddDoubleLine(format("  Multicraft %.0f%% x %.2f extra per item", procs.chances.multicraft * 100,
				procs.extraPerItem), signedMoney(procs.multicraft), 0.53, 0.53, 0.53, 0.53, 0.53, 0.53)
		end
		if procs.chances.resourcefulness > 0 then
			tip:AddDoubleLine(format("  Resourcefulness %.0f%% x %.0f%% saved", procs.chances.resourcefulness * 100,
				procs.savedShare * 100), signedMoney(procs.resourcefulness), 0.53, 0.53, 0.53, 0.53, 0.53, 0.53)
		end
	end
	local share = returnOf(row)
	if share then addPair(tip, "Return", ns.Format.Return(share)) end
	if row.unpriced > 0 then
		tip:AddLine(format("%d material(s) have no price, so profit is too high", row.unpriced), 1, 0.4, 0.4, true)
	end

	if row.concentration then
		local c = row.concentration
		tip:AddLine(" ")
		addLine(tip, format("With concentration: %s %s for %d concentration (%s per point)", rankIcon(row, c.quality),
			signedMoney(c.extra), c.points, Money(c.extra / c.points)))
	end

	-- Each rank's price and how many are listed, so a rank nobody buys shows.
	if entry.maxRank > 1 then
		tip:AddLine(" ")
		tip:AddLine("Ranks", 1, 0.82, 0)
		for _, rank in ipairs(ns.BestCrafts.Ranks(row)) do
			local price = rank.sale and Money(rank.sale) or Color("muted", "no price")
			local listed = rank.listed and format("%s listed", BreakUpLargeNumbers(rank.listed)) or ""
			addPair(tip, rankIcon(row, rank.rank) .. "  " .. price, listed)
		end
	end

	tip:AddLine(" ")
	addPair(tip, "Listed", listedText(row.listed, row.listedAge))
	local counted = math.max(ns.Sales.DaysCounted(), 1)
	addPair(tip, format("You sold (last %d day%s)", counted, counted == 1 and "" or "s"),
		row.itemName and tostring(row.sold) or Color("muted", "-"))
	if ns.Prices.HasTSM() then
		addPair(tip, "Sells per day in your region (TSM)", row.soldPerDay and perDayText(row.soldPerDay) or Color("muted", "-"))
	end
	if ns.Prices.HasSaleRate() then
		local tsm = (row.saleRateFrom or ns.Prices.SaleRateSource()) == "tsm"
		local label = tsm and "Sale rate in your region (TSM)" or "Your sale rate"
		local value = row.saleRate and ns.Format.SaleRate(row.saleRate) or Color("muted", "-")
		if row.saleRate and not tsm and row.saleRateSold and row.saleRateTotal then
			value = value .. " " .. Color("muted", format("(%d/%d)", row.saleRateSold, row.saleRateTotal))
		end
		addPair(tip, label, value)
	end
	if ns.Prices.HasTrend() then
		local tsm = ns.Prices.TrendSource() == "tsm"
		local label = ns.QUALITY_CRAFTING and (tsm and "Trend (TSM)" or "Trend")
			or (tsm and "Trend on your realm (TSM)" or "Trend on your realm")
		addPair(tip, label, row.trend and ns.Format.Trend(row.trend) or Color("muted", "-"))
	end
	local daily = goldPerDay(row)
	if daily then addPair(tip, "Gold per day", signedMoney(daily)) end
	if row.skillup then
		local s = row.skillup
		addPair(tip, "Per skill-up (" .. ns.Skillups.ChanceText(s.chance, s.color) .. ")", ns.Skillups.CostText(s.cost))
	end
	if row.firstCraft then addLine(tip, firstCraftMarkup(16) .. " First craft: gives profession knowledge") end
	if row.cooldown then addLine(tip, cooldownMarkup(14) .. " On cooldown: ready in " .. timeText(row.cooldown)) end

	tip:AddLine(" ")
	tip:AddLine(Color("simulated", ns.BestCrafts.IsMine(entry) and "Click: show the recipe"
		or "Log in to this character to craft it"))
	tip:AddLine(Color("simulated", "Right-click: shop, pin or ignore"))
end

---------------------------------------------------------------------------
-- Rows and column layout
---------------------------------------------------------------------------

-- Where each column sits in a row `width` wide: key -> { x, width }. Numeric
-- columns scale with the chosen text size; the item name takes what's left.
local function columnLayout(width)
	local m = metrics()
	local layout, right = {}, (width or DEFAULT_WIDTH) - 4
	for _, column in ipairs(COLUMNS) do
		if columnShown(column) then
			local base = (not ns.QUALITY_CRAFTING and column.foreverWidth)
				or (ns.db.precision == "gold" and column.goldWidth) or column.width
			local columnWidth = column.key == "actions" and ACTIONS_SIZE or math.floor(base * m.scale + 0.5)
			layout[column.key] = { x = right - columnWidth, width = columnWidth }
			right = right - columnWidth - CELL_GAP
		end
	end
	local nameX = m.iconX + m.iconSize + 6
	layout.name = { x = nameX, width = math.max(80, right - nameX) }
	return layout
end

local function actionsTooltip(self)
	local model = ns.BestCrafts.ShoppingModel(self.row)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if #model.missing > 0 then
		GameTooltip:SetText("Missing for 1 craft")
		for _, material in ipairs(model.missing) do ns.Shopping.AddMissingLine(GameTooltip, material.itemID, material.qty) end
	else
		GameTooltip:SetText("Nothing missing for 1 craft")
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(Color("simulated", "Click: shop, pin or ignore"))
	GameTooltip:Show()
end

local function cellText(button, key, justify)
	local text = button:CreateFontString(nil, "OVERLAY")
	text:SetFontObject(rowFont)
	text:SetJustifyH(justify or "RIGHT")
	text:SetWordWrap(false)
	button.cells[key] = text
	return text
end

-- Ignoring a recipe hides it from the list, for when its price makes no sense.
-- Pinning keeps it at the top. Both are kept for every character, by recipe.
local function setIgnored(row, ignored)
	local recipeID = row.entry.recipeID
	ns.db.bestIgnored[recipeID] = ignored or nil
	if ignored then ns.db.bestPinned[recipeID] = nil end
	BestCraftsList.Render()
end

local function setPinned(row, pinned)
	ns.db.bestPinned[row.entry.recipeID] = pinned or nil
	BestCraftsList.Render()
end

-- The row's menu, from its button or a right-click on the row.
local function openActions(owner, row)
	GameTooltip:Hide()
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(row.itemName or row.entry.name or "?")
		if ns.Shopping.ListTarget() then
			local model = ns.BestCrafts.ShoppingModel(row)
			root:CreateButton("Shop for 1 craft", function() ns.Shopping.Click(model, owner) end)
				:SetEnabled(#model.missing > 0)
			ns.Shopping.AddCraftCounts(root:CreateButton("Shop for more crafts"), model)
			root:CreateDivider()
		end
		local pinned, ignored = isPinned(row), ns.db.bestIgnored[row.entry.recipeID]
		root:CreateButton(pinned and "Unpin" or "Pin to top", function() setPinned(row, not pinned) end)
		root:CreateButton(ignored and "Stop ignoring" or "Ignore", function() setIgnored(row, not ignored) end)
	end)
end

local function createRow(button)
	button.cells = {}
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local stripe = button:CreateTexture(nil, "BACKGROUND")
	stripe:SetAllPoints()
	stripe:SetColorTexture(1, 1, 1, 0.035)
	button.stripe = stripe
	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.08)
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	button.pin = button:CreateFontString(nil, "OVERLAY")
	button.pin:SetFontObject(rowFont)
	button.pin:SetPoint("LEFT", 2, 0)
	cellText(button, "name", "LEFT")
	-- The rank and other icons, right after the name, so a long name that's cut
	-- short never hides them.
	button.tags = button:CreateFontString(nil, "OVERLAY")
	button.tags:SetFontObject(rowFont)
	button.tags:SetWordWrap(false)
	for _, column in ipairs(COLUMNS) do
		if column.header then cellText(button, column.key) end
	end

	-- Three dots, the usual sign for "more actions", drawn so they stay sharp.
	local actions = CreateFrame("Button", nil, button)
	actions:SetSize(ACTIONS_SIZE, ACTIONS_SIZE)
	for dot = -1, 1 do
		local texture = actions:CreateTexture(nil, "ARTWORK")
		texture:SetSize(ACTIONS_DOT, ACTIONS_DOT)
		texture:SetPoint("CENTER", 0, dot * ACTIONS_DOT_GAP)
		texture:SetColorTexture(1, 0.82, 0)
	end
	actions:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	actions:RegisterForClicks("LeftButtonUp")
	actions:SetScript("OnClick", function(self) openActions(self, self.row) end)
	actions:SetScript("OnEnter", actionsTooltip)
	actions:SetScript("OnLeave", GameTooltip_Hide)
	button.actions = actions

	button:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then
			openActions(self, self.row)
			return
		end
		if not ns.BestCrafts.IsMine(self.row.entry) then
			ns.Shopping.Say(format("Log in to %s to craft this.", ns.Ranks.CharacterName(crafterKey(self.row))))
			return
		end
		ns.Blizzard.OpenRecipe(self.row.entry.recipeID, self.row.entry.professionID)
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		rowTooltip(GameTooltip, self.row)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
end

local function drawRow(button, row)
	if not button.cells then createRow(button) end
	local m = metrics()
	button.row = row
	button.actions.row = row
	button.stripe:SetShown(row.stripe == true)
	button.icon:SetSize(m.iconSize, m.iconSize)
	button.icon:ClearAllPoints()
	button.icon:SetPoint("LEFT", m.iconX, 0)
	local reachY = math.max(0, (m.rowHeight - ACTIONS_SIZE) / 2)
	button.actions:SetHitRectInsets(-ACTIONS_REACH_LEFT, -ACTIONS_REACH_RIGHT, -reachY, -reachY)

	local layout = columnLayout(scrollBox:GetWidth())
	for key, text in pairs(button.cells) do
		local place = layout[key]
		text:SetShown(place ~= nil)
		if place then
			text:ClearAllPoints()
			text:SetPoint("LEFT", button, "LEFT", place.x, 0)
			text:SetWidth(place.width)
		end
	end
	button.actions:ClearAllPoints()
	button.actions:SetPoint("LEFT", button, "LEFT", layout.actions.x, 0)

	local entry = row.entry
	-- A recipe that makes no item (an enchant on WoW Forever) gets a scroll.
	button.icon:SetTexture(row.output and C_Item.GetItemIconByID(row.output.itemID) or ns.SCROLL_ICON)
	local name = row.itemName or entry.name or "?"
	local tags = {}
	if row.quality and entry.maxRank > 1 then tags[#tags + 1] = rankIcon(row, row.quality) end
	if row.firstCraft then tags[#tags + 1] = firstCraftMarkup(m.inlineIcon) end
	if row.cooldown then tags[#tags + 1] = cooldownMarkup(m.inlineIcon) end
	local ignored = ns.db.bestIgnored[entry.recipeID]
	if ignored then tags[#tags + 1] = Color("muted", "ignored") end
	local tagText = table.concat(tags, " ")
	button.tags:SetText(tagText)
	local nameCell = button.cells.name
	-- In its rarity's color; grey when ignored or without a price. An enchant that
	-- makes no item has no price to miss: it stays white.
	button.pin:SetText(isPinned(row) and pinMarkup(m.inlineIcon) or "")
	nameCell:SetText(((row.profit or not row.output) and not ignored)
		and ns.Format.RarityColored(row.output and row.output.itemID, name)
		or Color("muted", name))
	-- The name takes what the icons leave, and is cut short with "..." past that.
	local tagWidth = tagText ~= "" and (button.tags:GetUnboundedStringWidth() + TAG_GAP) or 0
	nameCell:SetWidth(math.max(1, math.min(nameCell:GetUnboundedStringWidth() + 2, layout.name.width - tagWidth)))
	button.tags:ClearAllPoints()
	button.tags:SetPoint("LEFT", nameCell, "RIGHT", TAG_GAP, 0)

	local profit = shownProfit(row)
	if profit then
		button.cells.profit:SetText(signedMoney(profit))
	else
		button.cells.profit:SetText(Color("muted", row.output and "No price" or "-"))
	end
	button.cells.plain:SetText(row.profit and signedMoney(row.profit) or Color("muted", "-"))
	local procs = row.profit and row.procs and row.procs.total
	button.cells.procs:SetText(procs and signedMoney(procs) or Color("muted", "-"))
	button.cells.cost:SetText((row.cost or 0) > 0 and Color("loss", Money(-row.cost)) or Color("muted", "-"))
	local share = returnOf(row)
	button.cells.returns:SetText(share and ns.Format.Return(share) or Color("muted", "-"))
	local daily = goldPerDay(row)
	button.cells.gold:SetText(daily and dailyText(daily) or Color("muted", "-"))
	-- A cost is gold spent, so it shows like Cost; a gain like Profit.
	button.cells.skillup:SetText(ns.Skillups.CostText(row.skillup and row.skillup.cost))
	button.cells.chance:SetText(ns.Skillups.ChancePercent(row.skillup and row.skillup.chance, row.skillup and row.skillup.color))
	local perPoint = SORT_VALUES.perPoint(row)
	button.cells.perPoint:SetText(perPoint and signedMoney(perPoint) or Color("muted", "-"))
	button.cells.crafter:SetText(ns.Ranks.CharacterName(crafterKey(row)))
	local listed = row.listed and BreakUpLargeNumbers(row.listed) or "-"
	button.cells.listed:SetText((row.listed and (row.listedAge or 0) < STALE_DAYS) and listed or Color("muted", listed))
	button.cells.perDay:SetText(row.soldPerDay and perDayText(row.soldPerDay) or Color("muted", "-"))
	button.cells.saleRate:SetText(row.saleRate and ns.Format.SaleRate(row.saleRate) or Color("muted", "-"))
	button.cells.trend:SetText(row.trend and ns.Format.Trend(row.trend) or Color("muted", "-"))
	button.cells.sold:SetText(not row.itemName and Color("muted", "-")
		or row.sold > 0 and tostring(row.sold) or Color("muted", "0"))
end

---------------------------------------------------------------------------
-- Headers, footer and drawing
---------------------------------------------------------------------------

-- One column header at `place` ({ x, width }), with an arrow beside the label
-- while it sorts: down for most first, up for least first. `sort` is its entry in
-- the sort chain. The first column there turns gold (`first`) and the second
-- light blue.
local function drawHeader(key, header, place, sort, first, headerHeight)
	header:ClearAllPoints()
	header:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", place.x, 0)
	header:SetSize(place.width, headerHeight)
	local label = key == "profit" and ns.db.countProcs and "Expected" or header.label
	header.text:SetText(sort and Color(first and "heading" or "secondSort", label) or label)
	local arrow = header.arrow
	arrow:SetShown(sort ~= nil)
	if not sort then return end
	if sort.ascending then arrow:SetTexCoord(0, 1, 1, 0) else arrow:SetTexCoord(0, 1, 0, 1) end
	arrow:ClearAllPoints()
	local textWidth = header.text:GetStringWidth()
	if key == "name" then
		arrow:SetPoint("LEFT", header, "LEFT", textWidth + 3, 0)
	else
		arrow:SetPoint("RIGHT", header, "RIGHT", -textWidth - 3, 0)
	end
end

local function updateHeaders()
	if not scrollBox then return end
	local m = metrics()
	local layout = columnLayout(scrollBox:GetWidth())
	local chain = sortChain()
	local orderOf = {}
	for order, sort in ipairs(chain) do orderOf[sort.key] = order end
	for key, header in pairs(headers) do
		local place = layout[key]
		header:SetShown(place ~= nil)
		if place then drawHeader(key, header, place, chain[orderOf[key]], orderOf[key] == 1, m.headerHeight) end
	end
end

local function applyFontIfChanged()
	local m = metrics()
	if appliedFontSize == m.size then return end
	appliedFontSize = m.size
	applyFontObject(rowFont, m.size)
	applyFontObject(headerFont, m.size)
	if headerBar then headerBar:SetHeight(m.headerHeight) end
	if scrollBox then
		scrollBox:ClearAllPoints()
		scrollBox:SetPoint("TOPLEFT", list.Inset, "TOPLEFT", INSET_PAD, -(INSET_PAD + m.headerHeight))
		scrollBox:SetPoint("BOTTOMRIGHT", list.Inset, "BOTTOMRIGHT", -SCROLLBAR_ROOM, INSET_PAD)
	end
	if scrollView and scrollView.SetElementExtent then scrollView:SetElementExtent(m.rowHeight) end
	if textSizeDropdown and textSizeDropdown.GenerateMenu then textSizeDropdown:GenerateMenu() end
end

function BestCraftsList.ApplyFont()
	appliedFontSize = nil
	applyFontIfChanged()
	if scrollBox and scrollBox.FullUpdate and ScrollBoxConstants then
		pcall(scrollBox.FullUpdate, scrollBox, ScrollBoxConstants.UpdateImmediately)
	end
	BestCraftsList.Render()
end

local function statusText(count, total)
	local done, scanTotal = ns.BestCrafts.Progress()
	if done then return format("Pricing %d of %d recipes...", done, scanTotal) end
	local scan = ns.BestCrafts.Current()
	if not scan then return "" end
	local text = count == total and format("%d recipes", total) or format("%d of %d recipes", count, total)
	return Color("muted", text .. " · Prices: " .. ns.Prices.SourceLabel()) .. ns.Reminder.FooterText()
end

function BestCraftsList.Render()
	refreshQueued = false
	if not (list and list:IsShown()) then return end
	applyFontIfChanged()
	local scan = ns.BestCrafts.Current()
	local shown = ns.db.bestAllCharacters and "All characters" or (scan and scan.name)
	list:SetTitle("Best crafts" .. (shown and ("  " .. Color("muted", shown)) or ""))
	if ns.db.bestAllCharacters then charactersButton:LockHighlight() else charactersButton:UnlockHighlight() end
	local rows, short = visibleRows()
	for index, row in ipairs(rows) do row.stripe = index % 2 == 0 end
	scrollBox:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants.RetainScrollPosition)
	status:SetText(statusText(#rows, #allRows))
	local note = emptyNote(#rows, short)
	emptyText:SetText(note or "")
	emptyText:SetShown(note ~= nil)
	-- The strategy and text size can change in the options too.
	if strategyDropdown then strategyDropdown:GenerateMenu() end
	if textSizeDropdown then textSizeDropdown:GenerateMenu() end
	updateHeaders()
end

-- A redraw swaps the rows' frames, which loses a click in progress and closes a
-- menu opened from one, so it waits for those.
local function renderWhenIdle()
	if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") or Menu.GetManager():GetOpenMenu() then
		C_Timer.After(REFRESH_DELAY, renderWhenIdle)
		return
	end
	BestCraftsList.Render()
end

-- Redraws once shortly, however many times it's called.
function BestCraftsList.Refresh()
	if refreshQueued or not (list and list:IsShown()) then return end
	refreshQueued = true
	C_Timer.After(REFRESH_DELAY, renderWhenIdle)
end

---------------------------------------------------------------------------
-- Sorting and column menus
---------------------------------------------------------------------------

-- Names and crafters A to Z, skill-ups cheapest first, the rest most first.
local function startsAscending(key)
	return key == "name" or key == "crafter" or key == "skillup"
end

-- A click sorts by that column alone, or reverses it. A shift-click (`chain`)
-- keeps the sort and adds the column after it, or reverses just that column when
-- the list already sorts by it.
local function setSort(key, chain)
	if not chain then
		if sortKey() == key then
			ns.db.bestSortAscending = not ns.db.bestSortAscending
		else
			ns.db.bestSort, ns.db.bestSortAscending = key, startsAscending(key)
		end
		wipe(ns.db.bestSortMore)
	elseif sortKey() == key then
		ns.db.bestSortAscending = not ns.db.bestSortAscending
	else
		-- Saved again as it sorts now, without the columns that are gone.
		local sorts, found = sortChain(), false
		ns.db.bestSort = sorts[1].key
		wipe(ns.db.bestSortMore)
		for i = 2, #sorts do
			local sort = sorts[i]
			if sort.key == key then
				sort.ascending, found = not sort.ascending, true
			end
			ns.db.bestSortMore[#ns.db.bestSortMore + 1] = { key = sort.key, ascending = sort.ascending }
		end
		if not found then
			-- With the list full, it takes the last column's place.
			if #ns.db.bestSortMore >= MAX_SORTS - 1 then table.remove(ns.db.bestSortMore) end
			ns.db.bestSortMore[#ns.db.bestSortMore + 1] = { key = key, ascending = startsAscending(key) }
		end
	end
	BestCraftsList.Render()
end

-- Which columns show: a checkbox for each one that can show now, left to right
-- as they sit in the list. Item, Profit and Crafter always show.
local function addColumnChoices(root)
	for i = #COLUMNS, 1, -1 do
		local column = COLUMNS[i]
		if column.header and not column.fixed and columnAvailable(column) then
			local box = root:CreateCheckbox(column.header, function() return columnChosen(column) end, function()
				-- Kept only while it differs from the default, so new defaults still reach you.
				local want = not columnChosen(column)
				if want == not column.offByDefault then want = nil end
				ns.db.bestColumns[column.key] = want
				BestCraftsList.Render()
			end)
			box:SetTooltip(function(tip)
				GameTooltip_SetTitle(tip, column.header)
				GameTooltip_AddNormalLine(tip, HEADER_TIPS[column.key] or "")
			end)
		end
	end
	root:CreateDivider()
	root:CreateButton("Default columns", function()
		wipe(ns.db.bestColumns)
		BestCraftsList.Render()
		return MenuResponse.Refresh
	end)
end

local function openColumnsMenu(owner)
	GameTooltip:Hide()
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Columns")
		addColumnChoices(root)
	end)
end

local function createHeader(key, label)
	local header = CreateFrame("Button", nil, list)
	header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	header.text = header:CreateFontString(nil, "OVERLAY") -- white; the sorted one turns gold
	header.text:SetFontObject(headerFont)
	header.text:SetAllPoints()
	header.text:SetJustifyH(key == "name" and "LEFT" or "RIGHT")
	header.label = label
	header.arrow = header:CreateTexture(nil, "OVERLAY")
	header.arrow:SetSize(SORT_ARROW_SIZE, SORT_ARROW_SIZE)
	if C_Texture.GetAtlasInfo(SORT_ARROW_ATLAS) then
		header.arrow:SetAtlas(SORT_ARROW_ATLAS)
	else
		header.arrow:SetTexture(SORT_ARROW_FILE)
	end
	header:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then return openColumnsMenu(self) end
		setSort(key, IsShiftKeyDown())
	end)
	header:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(label)
		GameTooltip:AddLine(HEADER_TIPS[key], 1, 1, 1, true)
		if key ~= "name" then GameTooltip:AddLine(Color("simulated", "Click to sort; click again to reverse.")) end
		GameTooltip:AddLine(Color("simulated", "Shift-click: sort by this second"))
		GameTooltip:AddLine(Color("simulated", "Right-click: pick the columns"))
		GameTooltip:Show()
	end)
	header:SetScript("OnLeave", GameTooltip_Hide)
	headers[key] = header
end

---------------------------------------------------------------------------
-- The filter menu
---------------------------------------------------------------------------

local function filtersAreDefault()
	return not ns.db.bestProfitableOnly and not ns.db.bestShowIgnored and next(ns.db.bestHidden) == nil
end

-- Back to the default filters. Ignored recipes stay ignored.
local function resetFilters()
	ns.db.bestProfitableOnly, ns.db.bestShowIgnored = false, false
	wipe(ns.db.bestHidden)
	BestCraftsList.Render()
end

-- How many of the profession's recipes are ignored.
local function ignoredCount()
	local count = 0
	for _, row in ipairs(allRows) do
		if ns.db.bestIgnored[row.entry.recipeID] then count = count + 1 end
	end
	return count
end

local function setAllGroups(hidden)
	for _, group in ipairs(ns.BestCrafts.GROUPS) do ns.db.bestHidden[group.key] = hidden or nil end
	BestCraftsList.Render()
	return MenuResponse.Refresh
end

-- Profitable only, then a checkbox for each kind of item the list has, with how many.
local function filterMenu(_, root)
	root:CreateCheckbox("Profitable only", function() return ns.db.bestProfitableOnly end, function()
		ns.db.bestProfitableOnly = not ns.db.bestProfitableOnly
		BestCraftsList.Render()
	end)
	local canCraft = root:CreateCheckbox("Can craft now", function() return ns.db.bestCanCraft end, function()
		ns.db.bestCanCraft = not ns.db.bestCanCraft
		BestCraftsList.Render()
	end)
	canCraft:SetTooltip(function(tip)
		GameTooltip_SetTitle(tip, "Can craft now")
		GameTooltip_AddNormalLine(tip, "Only show recipes you already have every material for, without changing your "
			.. "crafting strategy.")
	end)
	if ns.QUALITY_CRAFTING then
		local procs = root:CreateCheckbox("Count procs in profits", function() return ns.db.countProcs end,
			function() ns.Options.Set("countProcs", not ns.db.countProcs) end)
		procs:SetTooltip(function(tip)
			GameTooltip_SetTitle(tip, "Count procs in profits")
			GameTooltip_AddNormalLine(tip, "Profit becomes Expected: what a craft makes on average with procs, and the "
				.. "list ranks by it. Your chances come from the game; how big a proc is, from your own crafts.")
		end)
	end
	addColumnChoices(root:CreateButton("Columns"))
	root:CreateDivider()
	root:CreateTitle("Show")
	local counts = {}
	for _, row in ipairs(allRows) do counts[row.group] = (counts[row.group] or 0) + 1 end
	for _, group in ipairs(ns.BestCrafts.GROUPS) do
		local key = group.key
		-- Kinds the profession doesn't make aren't listed, unless they're hidden.
		if counts[key] or ns.db.bestHidden[key] then
			root:CreateCheckbox(format("%s %s", group.label, Color("muted", "(" .. (counts[key] or 0) .. ")")),
				function() return not ns.db.bestHidden[key] end,
				function()
					ns.db.bestHidden[key] = not ns.db.bestHidden[key] or nil
					BestCraftsList.Render()
				end)
		end
	end
	root:CreateDivider()
	root:CreateButton("Show all", function() return setAllGroups(false) end)
	root:CreateButton("Hide all", function() return setAllGroups(true) end)

	-- Recipes you ignored from their menu.
	local ignored = ignoredCount()
	root:CreateDivider()
	local show = root:CreateCheckbox(format("Show ignored recipes %s", Color("muted", "(" .. ignored .. ")")),
		function() return ns.db.bestShowIgnored end,
		function()
			ns.db.bestShowIgnored = not ns.db.bestShowIgnored
			BestCraftsList.Render()
		end)
	show:SetTooltip(function(tip)
		GameTooltip_SetTitle(tip, "Show ignored recipes")
		GameTooltip_AddNormalLine(tip, "Right-click a recipe in the list and pick Ignore, for when its price makes no sense. "
			.. "Ignored recipes show here in grey, marked ignored; pick Stop ignoring in the same menu to bring one back.")
	end)
	if ignored > 0 then
		root:CreateButton("Stop ignoring all", function()
			for _, row in ipairs(allRows) do ns.db.bestIgnored[row.entry.recipeID] = nil end
			BestCraftsList.Render()
			return MenuResponse.Refresh
		end)
	end
end

---------------------------------------------------------------------------
-- Window controls: text size, strategy, all characters, position & resize
---------------------------------------------------------------------------

local function textSizeMenu(_, root)
	root:CreateTitle("Text size")
	for _, size in ipairs(FONT_SIZES) do
		local label = size == MIN_FONT and format("%d pt (default)", size) or format("%d pt", size)
		root:CreateRadio(label, function() return fontSize() == size end, function()
			ns.Options.Set("bestFontSize", size)
		end, size)
	end
end

local function createTextSizeDropdown()
	textSizeDropdown = CreateFrame("DropdownButton", nil, list, "WowStyle1DropdownTemplate")
	textSizeDropdown:SetWidth(TEXT_SIZE_WIDTH)
	textSizeDropdown:SetPoint("TOPRIGHT", -SIDE, -TOP_BAR)
	if textSizeDropdown.SetSelectionTranslator then
		textSizeDropdown:SetSelectionTranslator(function(selection)
			return "Text: " .. (selection and selection.data or fontSize()) .. "pt"
		end)
	end
	textSizeDropdown:SetupMenu(textSizeMenu)
	textSizeDropdown:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Text size")
		GameTooltip:AddLine("Changes the font size and row spacing in the Best crafts window.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	textSizeDropdown:HookScript("OnLeave", GameTooltip_Hide)
end

local function createStrategyDropdown()
	strategyDropdown = CreateFrame("DropdownButton", nil, list, "WowStyle1DropdownTemplate")
	strategyDropdown:SetWidth(STRATEGY_WIDTH)
	strategyDropdown:SetPoint("BOTTOMRIGHT", -(SIDE + 12), 5)
	if strategyDropdown.SetSelectionTranslator then strategyDropdown:SetSelectionTranslator(ns.StrategyText) end
	strategyDropdown:SetupMenu(ns.StrategyMenu)
	local label = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("RIGHT", strategyDropdown, "LEFT", -6, 0)
	label:SetText(STRATEGY_LABEL)
	return STRATEGY_WIDTH + 6 + label:GetUnboundedStringWidth()
end

-- Between the status line and the strategy dropdown; lit while it's on.
local function createCharactersButton(strategyWidth)
	charactersButton = CreateFrame("Button", nil, list, "UIPanelButtonTemplate")
	charactersButton:SetText("All characters")
	charactersButton:SetSize(charactersButton:GetFontString():GetUnboundedStringWidth() + 24, 22)
	charactersButton:SetPoint("BOTTOMRIGHT", -(SIDE + 12 + strategyWidth + 12), 5)
	charactersButton:SetScript("OnClick", function()
		ns.db.bestAllCharacters = not ns.db.bestAllCharacters
		BestCraftsList.Render()
	end)
	charactersButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("All characters")
		GameTooltip:AddLine("Every profession of every character you've opened Best crafts on, in one list, at "
			.. "today's prices. Ranks and proc chances are from when that character last opened it.", 1, 1, 1, true)
		GameTooltip:AddLine(Color("simulated", ns.db.bestAllCharacters and "Click: back to this profession"
			or "Click: show them all"))
		GameTooltip:Show()
	end)
	charactersButton:SetScript("OnLeave", GameTooltip_Hide)
end

local function clampSize(w, h)
	w = math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor((w or DEFAULT_WIDTH) + 0.5)))
	h = math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, math.floor((h or DEFAULT_HEIGHT) + 0.5)))
	return w, h
end

local function saveLayout()
	if not (list and ns.db) then return end
	local w, h = clampSize(list:GetWidth(), list:GetHeight())
	local point, _, relPoint, x, y = list:GetPoint(1)
	ns.db.bestWindow = {
		w = w,
		h = h,
		point = type(point) == "string" and point or "CENTER",
		rel = type(relPoint) == "string" and relPoint or "CENTER",
		x = type(x) == "number" and x or 0,
		y = type(y) == "number" and y or 0,
	}
end

local function applySavedLayout()
	if not list then return end
	local saved = ns.db and ns.db.bestWindow
	local w, h = clampSize(saved and saved.w, saved and saved.h)
	list:SetSize(w, h)
	list:ClearAllPoints()
	if saved and type(saved.point) == "string" and type(saved.x) == "number" and type(saved.y) == "number" then
		list:SetPoint(saved.point, UIParent, saved.rel or saved.point, saved.x, saved.y)
	else
		list:SetPoint("CENTER")
	end
end

function BestCraftsList.ResetLayout()
	if ns.db then ns.db.bestWindow = nil end
	if list then
		applySavedLayout()
		BestCraftsList.Render()
	end
end

---------------------------------------------------------------------------
-- The notice over the list (old prices), drawn like Blizzard's Crafting Details box
---------------------------------------------------------------------------

local NOTICE_WIDTH, NOTICE_HEIGHT = 263, 200 -- the Crafting Details box's width, and room for the text
local NOTICE_SHADE_ALPHA = 0.7 -- how dark the list gets behind the notice
local NOTICE_SHADE_INSET = 4   -- inside the inset's border
local NOTICE_ART = { -- its background, top to bottom
	top = "Professions-QualityPane-bg-top",
	middle = "Professions-QualityPane-bg-middle",
	bottom = "Professions-QualityPane-bg-bottom",
	divider = "Professions-QualityPane-Divider",
}
local notice

local function noticeTexture(atlas)
	local texture = notice:CreateTexture(nil, "BACKGROUND")
	if C_Texture.GetAtlasInfo(atlas) then
		texture:SetAtlas(atlas)
	else
		texture:SetColorTexture(0.05, 0.05, 0.05, 0.95)
	end
	return texture
end

local function createNotice()
	-- The list darkens behind the notice, and takes no clicks until it's closed.
	local shade = CreateFrame("Frame", nil, list)
	shade:SetPoint("TOPLEFT", list.Inset, "TOPLEFT", NOTICE_SHADE_INSET, -NOTICE_SHADE_INSET)
	shade:SetPoint("BOTTOMRIGHT", list.Inset, "BOTTOMRIGHT", -NOTICE_SHADE_INSET, NOTICE_SHADE_INSET)
	shade:SetFrameLevel(scrollBox:GetFrameLevel() + 20)
	shade:EnableMouse(true)
	shade:Hide()
	local dark = shade:CreateTexture(nil, "BACKGROUND")
	dark:SetAllPoints()
	dark:SetColorTexture(0, 0, 0, NOTICE_SHADE_ALPHA)

	notice = CreateFrame("Frame", nil, shade)
	notice:SetSize(NOTICE_WIDTH, NOTICE_HEIGHT)
	notice:SetPoint("CENTER", scrollBox, "CENTER")
	notice:SetFrameLevel(shade:GetFrameLevel() + 5)
	notice.shade = shade

	local top = noticeTexture(NOTICE_ART.top)
	top:SetSize(NOTICE_WIDTH, 100)
	top:SetPoint("TOP")
	local bottom = noticeTexture(NOTICE_ART.bottom)
	bottom:SetSize(NOTICE_WIDTH, 100)
	bottom:SetPoint("BOTTOM", 0, -1)
	local middle = noticeTexture(NOTICE_ART.middle)
	middle:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
	middle:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT")

	local title = notice:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -25)
	title:SetText("Old prices")
	local divider = notice:CreateTexture(nil, "ARTWORK")
	divider:SetAtlas(NOTICE_ART.divider, true)
	divider:SetPoint("TOP", title, "BOTTOM", 0, -4)

	notice.text = notice:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	notice.text:SetPoint("TOP", divider, "BOTTOM", 0, -10)
	notice.text:SetWidth(NOTICE_WIDTH - 40)
	notice.text:SetJustifyH("CENTER")

	local okay = CreateFrame("Button", nil, notice, "UIPanelButtonTemplate")
	okay:SetText(OKAY)
	okay:SetSize(100, 22)
	okay:SetPoint("BOTTOM", 0, 22)
	okay:SetScript("OnClick", function() shade:Hide() end)
end

local function showNotice(text)
	notice.text:SetText(text)
	notice.shade:Show()
end

-- Testing (/craftonomics testnotice): shows the old prices notice on the open
-- list, whatever the scan's age. False when the list isn't open.
function BestCraftsList.TestNotice()
	if not (list and list:IsVisible()) then return false end
	showNotice("Auctionator's prices are from 4 days ago.\n\nThe profits in Best crafts may be far off. Run a full "
		.. "scan with Auctionator the next time you're at the auction house.")
	return true
end

local function createList()
	if list then return end
	local m = metrics()
	list = CreateFrame("Frame", "CraftonomicsBestCrafts", UIParent, "ButtonFrameTemplate")
	if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(list) end
	list:SetTitle("Best crafts")
	list:SetFrameStrata("HIGH")
	list:SetToplevel(true)
	list:SetMovable(true)
	list:SetResizable(true)
	if list.SetResizeBounds then
		list:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
	else
		if list.SetMinResize then list:SetMinResize(MIN_WIDTH, MIN_HEIGHT) end
		if list.SetMaxResize then list:SetMaxResize(MAX_WIDTH, MAX_HEIGHT) end
	end
	list:SetClampedToScreen(true)
	list:EnableMouse(true)
	list:RegisterForDrag("LeftButton")
	list:SetScript("OnDragStart", list.StartMoving)
	list:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		saveLayout()
	end)
	list:Hide()
	tinsert(UISpecialFrames, "CraftonomicsBestCrafts")
	applySavedLayout()

	list.Inset:ClearAllPoints()
	list.Inset:SetPoint("TOPLEFT", SIDE - 4, -INSET_TOP)
	list.Inset:SetPoint("BOTTOMRIGHT", -(SIDE - 4), FOOTER_BAR)

	local search = CreateFrame("EditBox", nil, list, "SearchBoxTemplate")
	search:SetSize(220, 20)
	search:SetPoint("TOPLEFT", SIDE + 6, -(TOP_BAR + 2))
	search:SetAutoFocus(false)
	search:SetFontObject("GameFontHighlight")
	search:HookScript("OnTextChanged", BestCraftsList.Refresh)
	if search.Instructions then
		search.Instructions:SetFontObject("GameFontDisable")
		search.Instructions:SetText("Item or material")
	end
	search:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Search")
		GameTooltip:AddLine("Finds recipes by the item they make, or by a material they use, like Copper Bar."
			.. (ns.db.bestAllCharacters and " In All characters, also by character." or ""), 1, 1, 1, true)
		GameTooltip:Show()
	end)
	search:HookScript("OnLeave", GameTooltip_Hide)
	list.Search = search

	local filter = CreateFrame("DropdownButton", nil, list, "WowStyle1FilterDropdownTemplate")
	filter:SetSize(FILTER_WIDTH, 22)
	filter:SetPoint("LEFT", search, "RIGHT", 12, 0)
	filter:SetText(FILTER)
	filter:SetupMenu(filterMenu)
	filter:SetIsDefaultCallback(filtersAreDefault)
	filter:SetDefaultCallback(resetFilters)

	createTextSizeDropdown()

	scrollBox = CreateFrame("Frame", nil, list, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", list.Inset, "TOPLEFT", INSET_PAD, -(INSET_PAD + m.headerHeight))
	scrollBox:SetPoint("BOTTOMRIGHT", list.Inset, "BOTTOMRIGHT", -SCROLLBAR_ROOM, INSET_PAD)
	local scrollBar = CreateFrame("EventFrame", nil, list, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
	scrollView = CreateScrollBoxListLinearView()
	scrollView:SetElementExtent(m.rowHeight)
	scrollView:SetElementInitializer("Button", drawRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, scrollView)

	headerBar = list:CreateTexture(nil, "BACKGROUND", nil, 1)
	headerBar:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", 0, 0)
	headerBar:SetPoint("BOTTOMRIGHT", scrollBox, "TOPRIGHT", 0, 0)
	headerBar:SetHeight(m.headerHeight)
	headerBar:SetColorTexture(0, 0, 0, 0.5)

	-- Why the list is empty, when it is (see emptyNote).
	emptyText = list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyText:SetPoint("CENTER", scrollBox, "CENTER", 0, EMPTY_LIFT)
	emptyText:SetWidth(EMPTY_WIDTH)
	emptyText:SetJustifyH("CENTER")
	emptyText:SetTextColor(0.6, 0.6, 0.6)
	emptyText:Hide()

	createNotice()
	createHeader("name", "Item")
	for _, column in ipairs(COLUMNS) do
		if column.header then createHeader(column.sort, column.header) end
	end

	local strategyWidth = createStrategyDropdown()
	createCharactersButton(strategyWidth)
	status = list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	status:SetPoint("BOTTOMLEFT", SIDE + 4, 10)
	status:SetPoint("RIGHT", charactersButton, "LEFT", -8, 0)
	status:SetJustifyH("LEFT")
	status:SetWordWrap(false)

	local grip = CreateFrame("Button", nil, list)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetNormalTexture(RESIZE_UP)
	grip:SetHighlightTexture(RESIZE_HIGHLIGHT)
	grip:SetPushedTexture(RESIZE_DOWN)
	grip:SetScript("OnMouseDown", function() list:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		list:StopMovingOrSizing()
		saveLayout()
		BestCraftsList.Render()
	end)

	list:SetScript("OnSizeChanged", function()
		updateHeaders()
		BestCraftsList.Refresh()
	end)
	list:SetScript("OnHide", function()
		GameTooltip:Hide()
		BestCraftsList.UpdateTab()
	end)

	-- Item names arrive from the server after first use; what you own changes what a craft costs you.
	list:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	list:RegisterEvent("BAG_UPDATE_DELAYED")
	list:SetScript("OnEvent", function(_, event)
		if event == "BAG_UPDATE_DELAYED" then ns.BestCrafts.Reprice() end
		BestCraftsList.Refresh()
	end)

	applyFontIfChanged()
end

---------------------------------------------------------------------------
-- Opening and closing
---------------------------------------------------------------------------

-- Whether the list can scan this character's active profession right now.
local function canShow()
	return ns.Blizzard.IsOwnProfession() and ns.Blizzard.ShowsRecipeList()
end

-- Shows the tab with the profession's own tabs, selected while the window is open,
-- and the panel's Ledger button on the crafting page and your crafting orders.
function BestCraftsList.UpdateTab()
	if not listTab then return end
	local page = ns.Blizzard.ActivePage()
	local own = ns.Blizzard.IsOwnProfession()
	ledgerButton:SetShown((page == "craft" and canShow()) or (page == "order" and own))
	local open = list ~= nil and list:IsShown()
	if listTab.side then
		listTab:SetShown(canShow())
		if listTab.checked ~= open then
			listTab.checked = open
			listTab:SetChecked(open)
		end
		local above = ns.Blizzard.LastSideTab(listTab)
		if listTab.before ~= above and above then
			listTab.before = above
			listTab:ClearAllPoints()
			listTab:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -SIDE_TAB_GAP)
		end
		return
	end
	listTab:SetShown(own and ns.Blizzard.TabsShown())
	if listTab.isSelected ~= open then listTab:SetTabSelected(open) end
	local before = ns.Blizzard.LastTab()
	if listTab.before ~= before then
		listTab.before = before
		listTab:ClearAllPoints()
		listTab:SetPoint("TOPLEFT", before, "TOPRIGHT", TAB_GAP, 0)
	end
end

-- The room the panel's first row leaves for the button.
function BestCraftsList.HeaderSpace()
	return ledgerButton and ledgerButton:IsShown() and (ledgerButton:GetWidth() + LEDGER_GAP) or 0
end

-- Whether you opened the list and haven't closed it, and which profession it last scanned.
local wantOpen = false
local openFor

function BestCraftsList.Show()
	createList()
	if not canShow() then return false end
	wantOpen, openFor = true, ns.Blizzard.ShownBaseProfession()
	list:Show()
	if list.Raise then list:Raise() end
	BestCraftsList.UpdateTab()
	ns.BestCrafts.Scan()
	BestCraftsList.Render()
	local text = ns.Reminder.BestCraftsNotice()
	if text then showNotice(text) end
	return true
end

function BestCraftsList.IsShown()
	return list ~= nil and list:IsVisible()
end

-- Closes the window, as you asked: the X button, Escape, the tab, the minimap button.
function BestCraftsList.Hide()
	if not list then return end
	wantOpen = false
	list:Hide()
	GameTooltip:Hide()
	BestCraftsList.UpdateTab()
end

-- Scans the newly opened profession once it finishes loading, while the window is open.
local function rescanSoon()
	local tries = 0
	local function try()
		if not wantOpen or not (list and list:IsShown()) then return end
		if canShow() then
			openFor = ns.Blizzard.ShownBaseProfession()
			ns.BestCrafts.Scan()
			BestCraftsList.Render()
			BestCraftsList.UpdateTab()
			return
		end
		tries = tries + 1
		if tries < REOPEN_TRIES then C_Timer.After(OPEN_RETRY, try) end
	end
	C_Timer.After(0, try)
end

-- The tab, from any page of the profession window: toggles the window.
local function openFromTab()
	if list and list:IsShown() then
		BestCraftsList.Hide()
		return
	end
	if BestCraftsList.Show() or not ns.Blizzard.IsOwnProfession() then return end
	-- From another page: back to the recipes, and show once they load.
	ns.Blizzard.ShowRecipesTab()
	local tries = 0
	local function try()
		tries = tries + 1
		if BestCraftsList.Show() or tries >= OPEN_TRIES then return end
		C_Timer.After(OPEN_RETRY, try)
	end
	C_Timer.After(0, try)
end

-- The crafting page showed another recipe. Switching to another profession
-- rescans the new profession while keeping the standalone window open; picking a
-- recipe in the same profession leaves the list open side-by-side.
local function onSelectRecipe()
	if list and list:IsShown() and canShow() and ns.Blizzard.ShownBaseProfession() ~= openFor then
		openFor = ns.Blizzard.ShownBaseProfession()
		ns.BestCrafts.Scan()
		BestCraftsList.Render()
	end
end

-- The crafting page switched view, showed or hid: keep the panel's button and
-- tab state updated, and rescan if the window is open on a new profession.
local function onLayout()
	BestCraftsList.UpdateTab()
	if list and list:IsShown() and wantOpen and not canShow() then
		rescanSoon()
	elseif list and list:IsShown() and canShow() and ns.Blizzard.ShownBaseProfession() ~= openFor then
		openFor = ns.Blizzard.ShownBaseProfession()
		ns.BestCrafts.Scan()
		BestCraftsList.Render()
	end
	ns.Panel.Refresh()
end

local function showTabTooltip(self)
	GameTooltip:SetOwner(self, self.side and "ANCHOR_RIGHT" or "ANCHOR_TOP")
	GameTooltip:SetText("Best crafts")
	GameTooltip:AddLine("Every recipe you know in this profession, in its own resizable window.", 1, 1, 1, true)
	GameTooltip:Show()
end

-- Forever's profession window has no tab bar: a side tab under its profession
-- tabs instead. A click opens the window, or closes it when it's open.
local function createSideTab()
	listTab = CreateFrame("Frame", nil, ProfessionsFrame, "LargeSideTabButtonTemplate")
	listTab.side = true
	listTab.Icon:SetTexture(SIDE_TAB_ICON)
	listTab:SetFillToInterior(true)
	listTab.checked = false
	listTab:SetChecked(false)
	listTab:Hide()
	listTab:SetCustomOnMouseUpHandler(function(_, button, upInside)
		if button ~= "LeftButton" or upInside == false then return end
		if list and list:IsShown() then BestCraftsList.Hide() else openFromTab() end
	end)
	listTab:SetScript("OnEnter", showTabTooltip)
	listTab:SetScript("OnLeave", GameTooltip_Hide)
	ns.Blizzard.WatchSideTabs(rescanSoon, BestCraftsList.UpdateTab)
end

-- The tab after the profession window's own.
local function createTab()
	if not ns.Blizzard.HasTabBar() then return createSideTab() end
	listTab = CreateFrame("Button", nil, ProfessionsFrame, "TabSystemButtonArtTemplate")
	listTab.selectedFontObject, listTab.unselectedFontObject = GameFontHighlight, GameFontNormal
	listTab:SetText("Best crafts")
	listTab:SetTabSelected(false)
	listTab:SetSize(listTab.Text:GetStringWidth() + TAB_TEXT_ROOM, ns.Blizzard.RecipesTab():GetHeight())
	listTab:Hide()
	listTab:SetScript("OnClick", openFromTab)
	listTab:SetScript("OnEnter", showTabTooltip)
	listTab:SetScript("OnLeave", GameTooltip_Hide)
	ns.Blizzard.WatchTabs(BestCraftsList.UpdateTab, BestCraftsList.UpdateTab)
end

-- The button at the top of the panel, left of its gear.
local function createLedgerButton()
	local panel = ns.Panel.Frame()
	ledgerButton = CreateFrame("Button", nil, panel)
	ledgerButton:SetSize(LEDGER_SIZE, LEDGER_SIZE)
	ledgerButton:SetPoint("TOPRIGHT", -LEDGER_RIGHT, -LEDGER_TOP)
	ledgerButton:SetFrameLevel(panel:GetFrameLevel() + 5)
	ledgerButton:SetNormalTexture(LEDGER_ICON)
	ledgerButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	ledgerButton:Hide()
	ledgerButton:SetScript("OnClick", ns.LedgerWindow.Toggle)
	ledgerButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Ledger")
		GameTooltip:AddLine("What you crafted, what sold, and how it compared with the forecast.", 1, 1, 1, true)
		GameTooltip:AddLine(Color("simulated", "Click: open the Ledger"))
		GameTooltip:Show()
	end)
	ledgerButton:SetScript("OnLeave", GameTooltip_Hide)
end

-- Creates the window, the tab and the panel's button. Safe to call more than once; needs the panel.
function BestCraftsList.Init()
	if list or not (ns.Blizzard.IsLoaded() and ns.Panel.Frame()) then return end
	createList()
	createTab()
	createLedgerButton()
	ns.BestCrafts.Watch(BestCraftsList.Refresh, function() return list ~= nil and list:IsShown() end)
	ns.Blizzard.WatchCraftingPage(onSelectRecipe, onLayout)
	ns.Panel.Refresh()
end
