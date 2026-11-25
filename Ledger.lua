-- Craftonomics: the ledger's records. What you crafted, sold, posted and used up,
-- kept packed as text so a long history stays small in the saved variables, and
-- only unpacked while the Ledger window is open. Which sale paid for which craft
-- isn't kept: Ledger.Analyze works that out each time, oldest craft first.
local _, ns = ...

local Ledger = {}
ns.Ledger = Ledger

local format = string.format

local KEEP_DAYS = 90       -- days kept in full; older ones are rolled up by month
local DAY = 86400
local SEP = "\t"
local PRICE_SLACK = 1      -- copper a sale's price may differ from what was posted
local CRAFT_SLACK = 3600   -- seconds a sale may seem to come before its craft (a mail's time is rough)
local MONEY_FLOOR = 1      -- rounding of the amounts saved, in copper
-- How long an auction lasts, in hours, by the game's number for the time it was
-- posted for: Retail's, or WoW Forever's. One posted before that was saved counts
-- as up for the longest.
local POST_HOURS = ns.QUALITY_CRAFTING and { 12, 24, 48 } or { 2, 8, 24 }
local MAX_POST_HOURS = POST_HOURS[#POST_HOURS]
local POST_DAYS = 3        -- what was posted longer ago than this isn't on the auction house or in the mail any more
-- Why a craft of yours is gone without a sale, and which of a craft's counts that
-- adds to: used yourself or destroyed (consumed), mailed, traded or put in the guild
-- bank (given), or written off in the Ledger window (written). One sold to a vendor
-- ("vendor") counts as sold instead.
local GONE_BUCKETS = { used = "consumed", destroyed = "consumed", given = "given", written = "written",
	disenchanted = "consumed" } -- on record that way for a short while, before a disenchant became a craft

-- The Disenchant spell: the recipe on record for what a disenchant gave (see
-- Ledger.RecordDisenchant).
Ledger.DISENCHANT = 13262
-- Enchanting's number in the game, for its name.
local ENCHANTING = 333

-- Kinds of craft. "craft" sells later; an order counts as sold, for what it paid,
-- when it's done.
Ledger.KINDS = {
	craft = "Regular crafts",
	patron = "Patron orders",
	personal = "Personal orders",
	guild = "Guild orders",
	public = "Public orders",
}
Ledger.KIND_ORDER = { "craft", "patron", "personal", "guild", "public" }

-- CraftonomicsDB.ledger = {
--   names = { "Name-Realm" or "Tailoring" ... }, shared by the records below,
--   items = itemID -> name, of what you've crafted,
--   days = day number -> { crafts, sales, posts, used }, each a string of lines:
--     crafts: time, character, profession, recipeID, itemID, rank, qty, kind,
--             value of one item then, materials cost, forecast profit with average
--             procs, profit at craft, forecast profit without procs, what procs really
--             added (older crafts stop at profit at craft), 1 when the materials
--             cost isn't known (crafted with the panel on something else).
--             What a disenchant gave is a craft too, with Ledger.DISENCHANT for
--             its recipe and no forecasts
--     sales:  time, character, item name, qty, gold after the cut, price of one
--     posts:  time, character, itemID, rank, qty, price of one, item name, hours
--             it was posted for (newer ones)
--     pulled: time, character, itemID, qty, price of one: an auction of yours
--             you cancelled
--     used:   time, itemID, qty (your own crafts used up as materials), 1 when the
--             craft they went into counted them at what they cost to make
--     bought: time, character, itemID, rank, qty, gold spent, market price of one
--             then, "auction" or "vendor", item name
--     gone:   time, character, itemID, qty, why (see GONE_BUCKETS, or "vendor"),
--             gold a vendor paid, rank (0 for any): your own crafts that left you
--             some other way than an auction or a craft
--   months = "2026-10" -> { crafts, items, cost, profit, spent }, for days past KEEP_DAYS,
--   seeded = the sales from before the ledger are in,
-- }
local saved
local demo -- made-up records in place of saved, for testing (see Ledger.ToggleDemo)
local nameIndex = {} -- name -> its place in saved.names
local costCache -- itemID -> { list = {}, index = 1 }, invalidated on non-disenchant mutations
local onChange = nop or function() end

function Ledger.Watch(changed)
	onChange = changed
end

---------------------------------------------------------------------------
-- Packing
---------------------------------------------------------------------------

local function split(line)
	local parts, count, start = {}, 0, 1
	while true do
		local stop = line:find(SEP, start, true)
		count = count + 1
		parts[count] = line:sub(start, stop and stop - 1 or -1)
		if not stop then return parts end
		start = stop + 1
	end
end

local function whole(amount)
	return math.floor((amount or 0) / MONEY_FLOOR + 0.5) * MONEY_FLOOR
end

local function dayOf(t)
	return math.floor(t / DAY)
end

-- A name's place in saved.names, adding it the first time.
local function indexOf(name)
	name = name or "?"
	local index = nameIndex[name]
	if not index then
		index = #saved.names + 1
		saved.names[index] = name
		nameIndex[name] = index
	end
	return index
end

local function appendRaw(list, t, ...)
	local day = saved.days[dayOf(t)]
	if not day then
		day = {}
		saved.days[dayOf(t)] = day
	end
	local fields = { t, ... }
	for i = 1, select("#", ...) + 1 do fields[i] = tostring(fields[i]) end
	day[list] = (day[list] or "") .. table.concat(fields, SEP) .. "\n"
end

local function append(list, t, ...)
	costCache = nil
	appendRaw(list, t, ...)
end

-- Calls fn with the fields of each line of `text`.
local function eachLine(text, fn)
	if not text then return end
	for line in text:gmatch("[^\n]+") do fn(split(line)) end
end

local function parseCraft(names, fields)
	local character, profession = tonumber(fields[2]), tonumber(fields[3])
	local itemID = tonumber(fields[5])
	local recipeID, cost = tonumber(fields[4]), tonumber(fields[10])
	-- Before this was saved, a craft with no recipe had no panel to take a cost from.
	local noCost = fields[15] == "1" or (fields[15] == nil and recipeID == 0 and itemID > 0 and cost == 0)
	return {
		t = tonumber(fields[1]), character = names[character], profession = names[profession],
		recipeID = recipeID, itemID = itemID > 0 and itemID or nil, rank = tonumber(fields[6]),
		qty = tonumber(fields[7]), kind = fields[8], unit = tonumber(fields[9]), cost = cost,
		forecast = tonumber(fields[11]), profit = tonumber(fields[12]),
		plain = tonumber(fields[13]), bonus = tonumber(fields[14]), noCost = noCost or nil,
	}
end

local function parseBought(names, fields)
	return { t = tonumber(fields[1]), character = names[tonumber(fields[2])], itemID = tonumber(fields[3]),
		rank = tonumber(fields[4]), qty = tonumber(fields[5]), spent = tonumber(fields[6]), market = tonumber(fields[7]),
		source = fields[8], name = fields[9] }
end

-- Everything in the saved days, unpacked and oldest first: crafts, sales, posts,
-- used, bought, gone, pulled.
function Ledger.Unpack(db)
	local crafts, sales, posts, used, bought, gone, pulled = {}, {}, {}, {}, {}, {}, {}
	local names = db.names
	for _, day in pairs(db.days) do
		eachLine(day.crafts, function(fields)
			local craft = parseCraft(names, fields)
			-- Older records hold imbues and poisons, which aren't crafts (see RecordCraft).
			if craft.itemID or craft.recipeID > 0 then crafts[#crafts + 1] = craft end
		end)
		eachLine(day.sales, function(fields)
			sales[#sales + 1] = { t = tonumber(fields[1]), character = names[tonumber(fields[2])], name = fields[3],
				qty = tonumber(fields[4]), money = tonumber(fields[5]), unit = tonumber(fields[6]) }
		end)
		eachLine(day.posts, function(fields)
			posts[#posts + 1] = { t = tonumber(fields[1]), character = names[tonumber(fields[2])], itemID = tonumber(fields[3]),
				rank = tonumber(fields[4]), qty = tonumber(fields[5]), unit = tonumber(fields[6]), name = fields[7],
				hours = tonumber(fields[8]) }
		end)
		eachLine(day.pulled, function(fields)
			pulled[#pulled + 1] = { t = tonumber(fields[1]), character = names[tonumber(fields[2])], itemID = tonumber(fields[3]),
				qty = tonumber(fields[4]), unit = tonumber(fields[5]) or 0 }
		end)
		eachLine(day.used, function(fields)
			used[#used + 1] = { t = tonumber(fields[1]), itemID = tonumber(fields[2]), qty = tonumber(fields[3]),
				atCost = fields[4] == "1" }
		end)
		eachLine(day.bought, function(fields) bought[#bought + 1] = parseBought(names, fields) end)
		eachLine(day.gone, function(fields)
			gone[#gone + 1] = { t = tonumber(fields[1]), character = names[tonumber(fields[2])], itemID = tonumber(fields[3]),
				qty = tonumber(fields[4]), reason = fields[5], money = tonumber(fields[6]) or 0, rank = tonumber(fields[7]) or 0 }
		end)
	end
	local function byTime(a, b) return a.t < b.t end
	table.sort(crafts, byTime)
	table.sort(sales, byTime)
	table.sort(posts, byTime)
	table.sort(used, byTime)
	table.sort(bought, byTime)
	table.sort(gone, byTime)
	table.sort(pulled, byTime)
	return crafts, sales, posts, used, bought, gone, pulled
end

---------------------------------------------------------------------------
-- Working out what sold
---------------------------------------------------------------------------

-- Where to start looking in `list` (oldest first): past the ones at its start with
-- nothing left, which stay that way. Kept on the list, so a long history isn't
-- gone through from the top for every sale.
local function firstLeft(list)
	local first = list.first or 1
	while list[first] and list[first].left <= 0 do first = first + 1 end
	list.first = first
	return first
end

-- Takes up to `qty` from the oldest crafts in `list` made by time `t` that still
-- have some left, of `rank` when it's known. take(craft, amount) does the rest.
-- Returns how many it couldn't place.
local function fromOldest(list, t, rank, qty, take)
	if not list then return qty end
	for index = firstLeft(list), #list do
		local craft = list[index]
		if qty <= 0 or craft.t > t then break end
		if craft.left > 0 and (not rank or rank == 0 or craft.rank == rank) then
			local amount = math.min(craft.left, qty)
			craft.left = craft.left - amount
			qty = qty - amount
			take(craft, amount)
		end
	end
	return qty
end

-- The post a sale came from: the same character, item name and price, posted
-- before it, still up (not cancelled or expired), with some left. Mails only
-- name the item, so this is what says which rank sold.
local function findPost(posts, sale)
	for index = firstLeft(posts), #posts do
		local post = posts[index]
		if post.t > sale.t then return end
		if post.left > post.pulled
			and post.character == sale.character
			and post.name == sale.name
			and sale.t <= post.t + (post.hours or MAX_POST_HOURS) * 3600 + 2 * CRAFT_SLACK
			and math.abs(post.unit - sale.unit) <= PRICE_SLACK then
			return post
		end
	end
end

-- Spreads sales and materials used over the crafts, oldest first. Each regular
-- craft with an item gets left, sold, money (after the cut), used and soldDays.
-- A sale no craft accounts for counts toward what you bought of it (resold and
-- resoldMoney on each purchase). What left you some other way comes off what's
-- left too: sold to a vendor counts as sold (vendored), the rest as consumed, given
-- or written (see GONE_BUCKETS), which add up to gone. Returns the crafts, oldest
-- first, what sold with neither on record ({ qty, money }), the purchases, oldest
-- first, and the posts, each with what's left of it unsold, and `up`: how many of
-- it are on the auction house right now (not sold, not cancelled, its time not
-- over). Each craft gets posted, how many of what's left of it are up, and
-- postedMoney, what they're posted for after the cut.
function Ledger.Analyze(db)
	local crafts, sales, posts, used, bought, gone, pulled = Ledger.Unpack(db)
	local byItem, byName, boughtByName = {}, {}, {}
	for _, entry in ipairs(bought) do
		entry.left, entry.resold, entry.resoldMoney = entry.qty, 0, 0
		local list = boughtByName[entry.name]
		if not list then
			list = {}
			boughtByName[entry.name] = list
		end
		list[#list + 1] = entry
	end
	-- When you disenchanted: what was used up at that moment went into it.
	local disenchants = {}
	for _, craft in ipairs(crafts) do
		if craft.recipeID == Ledger.DISENCHANT then disenchants[craft.t] = true end
		craft.left, craft.sold, craft.money, craft.used, craft.soldDays = 0, 0, 0, 0, 0
		craft.usedAtCost, craft.disenchanted = 0, 0
		craft.vendored, craft.consumed, craft.given, craft.written = 0, 0, 0, 0
		craft.posted, craft.postedMoney = 0, 0
		if craft.kind == "craft" and craft.itemID then
			craft.left = craft.qty
			local list = byItem[craft.itemID]
			if not list then
				list = {}
				byItem[craft.itemID] = list
			end
			list[#list + 1] = craft
			local name = db.items[craft.itemID]
			if name then
				local named = byName[name]
				if not named then
					named = {}
					byName[name] = named
				end
				named[#named + 1] = craft
			end
		end
	end
	for _, post in ipairs(posts) do post.left, post.pulled, post.up = post.qty, 0, 0 end

	-- In time order, so what was used up and what sold take from the same crafts.
	local events = {}
	for _, sale in ipairs(sales) do events[#events + 1] = sale end
	for _, entry in ipairs(used) do
		entry.isUsed = true
		events[#events + 1] = entry
	end
	for _, entry in ipairs(gone) do
		entry.isGone = true
		events[#events + 1] = entry
	end
	for _, entry in ipairs(pulled) do
		entry.isPulled = true
		events[#events + 1] = entry
	end
	table.sort(events, function(a, b) return a.t < b.t end)

	local other = { qty = 0, money = 0 }
	for _, event in ipairs(events) do
		if event.isUsed then
			fromOldest(byItem[event.itemID], event.t, nil, event.qty, function(craft, amount)
				craft.used = craft.used + amount
				if event.atCost then craft.usedAtCost = craft.usedAtCost + amount end
				if event.atCost and disenchants[event.t] then craft.disenchanted = craft.disenchanted + amount end
			end)
		elseif event.isPulled then
			-- Cancelled: off the newest auction of it at that price that still had some up.
			local qty = event.qty
			for index = #posts, 1, -1 do
				if qty <= 0 then break end
				local post = posts[index]
				if post.t <= event.t
					and event.t <= post.t + (post.hours or MAX_POST_HOURS) * 3600 + CRAFT_SLACK
					and post.character == event.character and post.itemID == event.itemID
					and math.abs(post.unit - event.unit) <= PRICE_SLACK and post.left > post.pulled then
					local amount = math.min(post.left - post.pulled, qty)
					post.pulled = post.pulled + amount
					qty = qty - amount
				end
			end
		elseif event.isGone then
			local each = event.money / event.qty
			local bucket = GONE_BUCKETS[event.reason] or "written"
			fromOldest(byItem[event.itemID], event.t + CRAFT_SLACK, event.rank, event.qty, function(craft, amount)
				if event.reason == "vendor" then
					-- Sold, for what the vendor paid.
					craft.sold = craft.sold + amount
					craft.vendored = craft.vendored + amount
					craft.money = craft.money + each * amount
					craft.soldDays = craft.soldDays + amount * math.max(event.t - craft.t, 0) / DAY
				else
					craft[bucket] = craft[bucket] + amount
				end
			end)
		else
			local post = findPost(posts, event)
			local list, rank = byName[event.name], nil
			if post then
				post.left = math.max(post.left - event.qty, post.pulled)
				list, rank = byItem[post.itemID] or list, post.rank
			end
			local each = event.money / event.qty
			-- A mail's time is rough, so a sale may seem to come a little before its craft.
			local by = event.t + CRAFT_SLACK
			local unplaced = fromOldest(list, by, rank, event.qty, function(craft, amount)
				craft.sold = craft.sold + amount
				craft.money = craft.money + each * amount
				craft.soldDays = craft.soldDays + amount * math.max(event.t - craft.t, 0) / DAY
			end)
			unplaced = fromOldest(boughtByName[event.name], by, rank, unplaced, function(entry, amount)
				entry.resold = entry.resold + amount
				entry.resoldMoney = entry.resoldMoney + each * amount
			end)
			other.qty = other.qty + unplaced
			other.money = other.money + each * unplaced
		end
	end

	-- What's on the auction house right now, and whose crafts those are: each
	-- auction still up counts toward that character's oldest crafts of the item
	-- with some left. Blizzard's owned-auction snapshot (`db.live`) overrides any
	-- older `posts` records for that character so auctions posted outside
	-- Craftonomics' hooks (e.g. Auctionator) or via confirmation still show.
	local now = time()
	local keep = (ns.db and ns.db.ahCut) and (1 - ns.AH_CUT) or 1
	local function assignPosted(character, itemID, rank, qty, unit)
		for _, craft in ipairs(qty > 0 and byItem[itemID] or {}) do
			if qty <= 0 then break end
			local free = craft.left - craft.posted
			if free > 0 and craft.character == character and (rank == 0 or craft.rank == rank) then
				local amount = math.min(free, qty)
				craft.posted = craft.posted + amount
				craft.postedMoney = craft.postedMoney + amount * unit * keep
				qty = qty - amount
			end
		end
	end
	for _, post in ipairs(posts) do
		if now < post.t + (post.hours or MAX_POST_HOURS) * 3600 then post.up = math.max(post.left - post.pulled, 0) end
		local snap = db.live and db.live[post.character]
		if not snap or post.t > snap.at then
			assignPosted(post.character, post.itemID, post.rank, post.up, post.unit)
		end
	end
	for character, snap in pairs(db.live or {}) do
		local live = {}
		for _, entry in ipairs(snap.list or {}) do
			if (entry.qty or 0) > 0 and (not entry.expiresAt or now < entry.expiresAt) then
				live[#live + 1] = { itemID = entry.itemID, rank = entry.rank or 0, qty = entry.qty, unit = entry.unit or 0 }
			end
		end
		for _, sale in ipairs(sales) do
			if sale.character == character and sale.t > (snap.at or 0) + 300 then
				local rem = sale.qty
				for _, entry in ipairs(live) do
					if rem <= 0 then break end
					if entry.qty > 0 and db.items[entry.itemID] == sale.name
						and math.abs(entry.unit - sale.unit) <= PRICE_SLACK then
						local take = math.min(entry.qty, rem)
						entry.qty = entry.qty - take
						rem = rem - take
					end
				end
			end
		end
		for _, entry in ipairs(live) do
			if entry.qty > 0 then
				assignPosted(character, entry.itemID, entry.rank, entry.qty, entry.unit)
			end
		end
	end

	-- What's known so far of each craft. Procs are luck, so the forecast leaves them
	-- out and so does what it's compared with. Older crafts only have the forecast
	-- with procs, and hasProcs false.
	for _, craft in ipairs(crafts) do
		craft.gone = craft.consumed + craft.given + craft.written
		craft.hasProcs = craft.plain ~= nil
		local forecast, bonus = craft.plain or craft.forecast, craft.bonus or 0
		if craft.kind == "craft" and craft.itemID then
			local share = craft.cost / craft.qty
			local done = craft.sold + craft.used
			craft.pending = craft.left * craft.unit
			if craft.noCost then
				-- What it sold for is known, what it cost isn't: no profit to show.
				craft.earned, craft.expected, craft.procGain = 0, 0, 0
			else
				-- Used in another craft counts as sold to it. For what it was worth then, when
				-- that craft's cost counted it at that; when it counted it at what it cost
				-- to make, the gain is all in that craft's profit and there's none here.
				local worth = craft.used - craft.usedAtCost
				craft.earned = craft.money + (craft.unit - share) * worth - share * craft.sold
				local priced = craft.unit > 0 and (craft.unit - share) * craft.qty or 0
				craft.expected = forecast ~= 0 and forecast or priced
				craft.procGain = bonus * done / craft.qty
				-- Compared with what the panel said, so only when it was open, and only
				-- what was sold or used for what it was worth.
				local compared = craft.sold + worth
				if forecast ~= 0 and compared > 0 then
					craft.compareActual = craft.earned - craft.procGain
					craft.compareForecast = forecast * compared / craft.qty
				end
			end
		else
			craft.earned = craft.profit
			craft.pending = 0
			craft.expected = forecast
			craft.procGain = bonus
			if forecast ~= 0 then
				craft.compareActual, craft.compareForecast = craft.profit - bonus, forecast
			end
			if craft.kind ~= "craft" then
				craft.sold = craft.qty
				craft.money = craft.profit + craft.cost
				if forecast ~= 0 then craft.unit = (forecast + math.max(craft.cost + bonus, 0)) / craft.qty end
			end
		end
		-- What resourcefulness returns can beat what you put in: a gain, already in
		-- the profit, not negative spending.
		craft.cost = math.max(craft.cost, 0)
	end
	return crafts, other, bought, posts
end

-- One row per item and rank in `bought`: { itemID, rank, name, source, qty, spent,
-- unitPaid, unitMarket and vsMarket (against the market price, where there was
-- one), resold, resoldMoney, resaleProfit }.
function Ledger.BoughtItems(bought)
	local groups, list = {}, {}
	for _, entry in ipairs(bought) do
		local key = format("%d:%d", entry.itemID, entry.rank)
		local group = groups[key]
		if not group then
			group = { itemID = entry.itemID, rank = entry.rank, name = entry.name, source = entry.source, qty = 0, spent = 0,
				resold = 0, resoldMoney = 0, resoldCost = 0, marketQty = 0, marketPaid = 0, marketWorth = 0 }
			groups[key] = group
			list[#list + 1] = group
		end
		group.qty = group.qty + entry.qty
		group.spent = group.spent + entry.spent
		group.resold = group.resold + entry.resold
		group.resoldMoney = group.resoldMoney + entry.resoldMoney
		group.resoldCost = group.resoldCost + entry.spent / entry.qty * entry.resold
		if entry.market > 0 then
			group.marketQty = group.marketQty + entry.qty
			group.marketPaid = group.marketPaid + entry.spent
			group.marketWorth = group.marketWorth + entry.market * entry.qty
		end
	end
	for _, group in ipairs(list) do
		group.unitPaid = group.spent / group.qty
		if group.marketWorth > 0 then
			group.unitMarket = group.marketWorth / group.marketQty
			group.vsMarket = (group.marketPaid - group.marketWorth) / group.marketWorth
		end
		if group.resold > 0 then group.resaleProfit = group.resoldMoney - group.resoldCost end
	end
	return list
end

-- Totals for a list of crafts: { crafts, items, cost, earned, pending, unsold,
-- sold, money, expected, procs, actual, forecast, unknown, used (with usedAtCost
-- and disenchanted, which are part of it), and gone with its
-- parts vendored, consumed, given and written }. Expected is the profit
-- forecast for all of them, procs what they really added; actual and forecast only
-- count what's done, without procs, so they can be compared. Unknown is how many
-- have no materials cost on record, and so no profit.
--
-- Posted and postedMoney are what's on the auction house of what's left, and what
-- it's posted for after the cut; keptWorth is what the rest of what's left was
-- worth when crafted.
--
-- The crafts with a cost on record add up on their own: knownSold of them sold
-- for knownMoney, their materials cost soldCost, and usedGain is what the ones
-- used in your own crafts made (counted as sold to that craft for what they were
-- worth then), so earned = knownMoney - soldCost + usedGain. knownPosted of
-- them are on the auction house for knownPostedMoney, and those cost postedCost.
-- The ones with no cost on record: unknownSold sold for unknownMoney, and
-- unknownLeft are left, worth unknownWorth when crafted.
function Ledger.Summarize(crafts)
	local total = { crafts = 0, items = 0, cost = 0, earned = 0, pending = 0, unsold = 0, sold = 0, money = 0,
		expected = 0, procs = 0, actual = 0, forecast = 0, unknown = 0, used = 0, usedAtCost = 0, disenchanted = 0,
		gone = 0, vendored = 0, consumed = 0, given = 0, written = 0,
		posted = 0, postedMoney = 0, keptWorth = 0,
		knownSold = 0, knownMoney = 0, soldCost = 0, usedGain = 0, knownPosted = 0, knownPostedMoney = 0, postedCost = 0,
		unknownSold = 0, unknownMoney = 0, unknownLeft = 0, unknownWorth = 0 }
	for _, craft in ipairs(crafts) do
		local posted, postedMoney = craft.posted or 0, craft.postedMoney or 0
		total.posted = total.posted + posted
		total.postedMoney = total.postedMoney + postedMoney
		total.keptWorth = total.keptWorth + (craft.left - posted) * (craft.unit or 0)
		if craft.noCost then
			total.unknownSold = total.unknownSold + craft.sold
			total.unknownMoney = total.unknownMoney + craft.money
			total.unknownLeft = total.unknownLeft + craft.left
			total.unknownWorth = total.unknownWorth + craft.pending
		elseif craft.kind == "craft" and craft.itemID then
			local share = craft.cost / craft.qty
			total.knownSold = total.knownSold + craft.sold
			total.knownMoney = total.knownMoney + craft.money
			total.soldCost = total.soldCost + share * craft.sold
			total.usedGain = total.usedGain + (craft.unit - share) * (craft.used - craft.usedAtCost)
			total.knownPosted = total.knownPosted + posted
			total.knownPostedMoney = total.knownPostedMoney + postedMoney
			total.postedCost = total.postedCost + share * posted
		else
			-- An order, paid when it's done, or a craft that made nothing to sell.
			total.knownSold = total.knownSold + craft.sold
			total.knownMoney = total.knownMoney + craft.earned + craft.cost
			total.soldCost = total.soldCost + craft.cost
		end
		total.crafts = total.crafts + 1
		total.used = total.used + craft.used
		total.usedAtCost = total.usedAtCost + craft.usedAtCost
		total.disenchanted = total.disenchanted + craft.disenchanted
		total.gone = total.gone + craft.gone
		total.vendored = total.vendored + craft.vendored
		total.consumed = total.consumed + craft.consumed
		total.given = total.given + craft.given
		total.written = total.written + craft.written
		if craft.noCost then total.unknown = total.unknown + 1 end
		total.items = total.items + craft.qty
		total.cost = total.cost + craft.cost
		total.earned = total.earned + craft.earned
		total.pending = total.pending + craft.pending
		total.unsold = total.unsold + craft.left
		total.sold = total.sold + craft.sold
		total.money = total.money + craft.money
		total.expected = total.expected + craft.expected
		total.procs = total.procs + craft.procGain
		if craft.compareForecast then
			total.actual = total.actual + craft.compareActual
			total.forecast = total.forecast + craft.compareForecast
		end
	end
	return total
end

-- How far a total landed from its forecast, as a share (-0.09 is 9% under). Nil
-- with nothing to compare.
function Ledger.Off(total)
	if total.forecast == 0 then return end
	return (total.actual - total.forecast) / math.abs(total.forecast)
end

-- `crafts` with the ones in the same minute merged into one, when they're the same
-- item and rank, by the same character, of the same type. `count` says how many
-- each stands for, and `unit` is their average.
function Ledger.Merge(crafts)
	local merged, list = {}, {}
	for _, craft in ipairs(crafts) do
		local key = format("%d:%s:%d:%d:%s:%s:%s", math.floor(craft.t / 60), tostring(craft.itemID), craft.recipeID, craft.rank,
			tostring(craft.character), craft.kind, tostring(craft.noCost))
		local row = merged[key]
		if not row then
			row = {}
			for field, value in pairs(craft) do row[field] = value end
			row.count, row.unit = 1, craft.unit * craft.qty
			merged[key] = row
			list[#list + 1] = row
		else
			row.count = row.count + 1
			row.unit = row.unit + craft.unit * craft.qty
			for _, field in ipairs({ "qty", "cost", "forecast", "profit", "left", "sold", "money", "used", "usedAtCost", "soldDays", "earned", "pending",
				"expected", "procGain", "gone", "vendored", "consumed", "given", "written", "disenchanted", "posted", "postedMoney" }) do
				row[field] = (row[field] or 0) + (craft[field] or 0)
			end
		end
	end
	for _, row in ipairs(list) do row.unit = row.unit / row.qty end
	return list
end

-- One row per item, rank and kind of craft in `crafts`, since a patron order and a
-- personal one for the same item pay nothing alike: { itemID, rank, kind, recipeID,
-- counts as Summarize, plus, per item, unitForecast, unitProcs and unitProfit (of
-- what's done; unitProcs only from crafts that saved it),
-- unitPrice (the sale price or an order's pay expected), unitCost and unitSold, days
-- (to sell, for regular crafts), and margin (the share of what sold that was profit,
-- 0.26 is 26%), and made = its crafts }.
function Ledger.Items(crafts)
	local groups, list = {}, {}
	for _, craft in ipairs(crafts) do
		if craft.itemID then
			local key = format("%d:%d:%s", craft.itemID, craft.rank, craft.kind)
			local group = groups[key]
			if not group then
				group = { itemID = craft.itemID, rank = craft.rank, kind = craft.kind, recipeID = craft.recipeID, made = {} }
				groups[key] = group
				list[#list + 1] = group
			end
			group.made[#group.made + 1] = craft
		end
	end
	for _, group in ipairs(list) do
		local total = Ledger.Summarize(group.made)
		for key, value in pairs(total) do group[key] = value end
		local soldForecast, soldDays, madeForecast, priced, soldCost, listed, done = 0, 0, 0, 0, 0, 0, 0
		local procsDone, procsGain = 0, 0
		-- Only crafts with a cost on record count toward cost, profit and margin.
		local costed, costedMoney = 0, 0
		for _, craft in ipairs(group.made) do
			soldForecast = soldForecast + craft.unit * craft.sold
			if not craft.noCost then
				soldCost = soldCost + craft.cost / craft.qty * craft.sold
				-- What was used at its cost made nothing here, so it isn't in the average.
				done = done + craft.sold + craft.used - craft.usedAtCost
				costed = costed + craft.qty
				costedMoney = costedMoney + craft.money
			end
			if craft.hasProcs and not craft.noCost then
				procsDone = procsDone + craft.sold + craft.used
				procsGain = procsGain + craft.procGain
			end
			soldDays = soldDays + craft.soldDays
			if craft.kind == "craft" then listed = listed + craft.sold end
			if craft.unit > 0 then
				madeForecast = madeForecast + craft.unit * craft.qty
				priced = priced + craft.qty
			end
		end
		-- What sold is what to compare with, once anything has.
		if priced > 0 then group.unitPrice = madeForecast / priced end
		if total.expected ~= 0 and costed > 0 then group.unitForecast = total.expected / costed end
		if done > 0 then group.unitProfit = total.earned / done end
		if procsDone > 0 then group.unitProcs = procsGain / procsDone end
		if costed > 0 then group.unitCost = total.cost / costed end
		if listed > 0 then group.days = soldDays / listed end
		if total.sold > 0 then
			group.unitSold = total.money / total.sold
			group.unitPrice = soldForecast / total.sold
			if costedMoney > 0 then group.margin = (costedMoney - soldCost) / costedMoney end
		end
	end
	return list
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

local function me()
	local _, key = ns.Ranks and ns.Ranks.Me and ns.Ranks.Me()
	return key or format("%s-%s", UnitName("player") or "?", GetNormalizedRealmName() or "?")
end

-- The rank in an item's link, or `fallback`: crafted items carry it in the link,
-- ranked materials are a separate item each.
local function rankOf(link, fallback)
	if C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
		local ok, rank = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, link)
		if ok and rank and rank > 0 then return rank end
	end
	if C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityByItemInfo then
		local ok, rank = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, link)
		if ok and rank and rank > 0 then return rank end
	end
	return fallback or 0
end

-- The item's name in a link, without the rank's icon.
local function nameIn(link)
	local name = link and link:match("%[(.-)%]")
	return name and strtrim((name:gsub("|A.-|a", "")))
end

local function kindOf(model)
	if not model or model.kind ~= "order" then return "craft" end
	local types = Enum.CraftingOrderType
	if model.orderType == types.Npc then return "patron" end
	if model.orderType == types.Personal then return "personal" end
	if model.orderType == types.Guild then return "guild" end
	return "public"
end

-- The kind of a craft with no model, from how it was started (see Results.lua).
local function kindStarted(started)
	if not (started and started.orderID and C_CraftingOrders) then return "craft" end
	local order = C_CraftingOrders.GetClaimedOrder()
	return kindOf({ kind = "order", orderType = order and order.orderType })
end

-- A craft that just finished: the game's result, the model on screen and what
-- Results worked out. With the panel hidden or on another recipe there's no model:
-- no forecast and no materials cost, and `started` says what's known of the craft.
function Ledger.RecordCraft(data, model, result, started)
	if not saved then return end
	local t = time()
	local link = data.hyperlink ~= "" and data.hyperlink or nil
	local itemID = data.itemID
	-- An enchant on a vellum makes the scroll the panel priced.
	if data.isEnchant then
		link = model and model.output and model.output.link
		itemID = link and C_Item.GetItemInfoInstant(link)
	end
	-- A recraft, or a recipe that makes nothing to sell.
	if model and model.kind == "craft" and not model.output then link = nil end
	if not link then itemID = nil end
	-- A shaman's imbue or a rogue's poison reports as an enchant, with no recipe open.
	if not (itemID or model) then return end
	local kind = model and kindOf(model) or kindStarted(started)
	local qty = math.max(data.quantity or 1, 1)
	local unit = result and result.unit
	if not unit and link and kind == "craft" then
		local price = ns.Prices.Sale(link, itemID)
		unit = price and (ns.db.ahCut and price * (1 - ns.AH_CUT) or price)
	end
	local cost = model and (model.realCost or 0) - (result and result.savedValue or 0) or 0
	local actual = result and result.actual or 0
	local recipeID = model and model.recipeID or (started and started.recipeID) or 0
	local profession = recipeID > 0 and C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)
	if itemID then saved.items[itemID] = saved.items[itemID] or nameIn(link) end

	append("crafts", t, indexOf(me()), indexOf(profession and profession.professionName), recipeID, itemID or 0,
		rankOf(link, data.craftingQuality), qty, kind, whole(unit), whole(cost),
		whole(model and ns.Model.Shown(model)), whole(actual), whole(model and model.total), whole(result and result.bonus),
		model and 0 or 1)

	-- Your own crafts used as materials aren't waiting to sell.
	local returned = {}
	for _, entry in ipairs(data.resourcesReturned or {}) do
		local id = entry.reagent and entry.reagent.itemID
		if id then returned[id] = (returned[id] or 0) + (entry.quantity or 0) end
	end
	for _, material in ipairs(model and model.materials or {}) do
		if saved.items[material.itemID] then
			local spent = material.qty - (returned[material.itemID] or 0)
			-- Crafted (Craft myself, Cheapest way): this craft's cost counted it at
			-- what it costs to make.
			local atCost = ns.Chains.Cost(material.itemID) ~= nil
			if spent > 0 then append("used", t, material.itemID, spent, atCost and 1 or 0) end
		end
	end
	onChange()
end

-- A sale from the mailbox (see Sales.lua).
function Ledger.RecordSale(sale)
	if not saved or (sale.qty or 0) <= 0 then return end
	local keep = ns.db.ahCut and (1 - ns.AH_CUT) or 1
	append("sales", sale.t, indexOf(me()), sale.name, sale.qty, whole(sale.net or sale.money * keep),
		whole(sale.money / sale.qty))
	onChange()
end

-- Something you crafted left you some other way than an auction or a craft (see
-- Gone.lua): `reason` is "vendor" (with what the vendor paid), "used", "destroyed",
-- "given" or "written". `rank` when it's known which.
function Ledger.RecordGone(itemID, qty, reason, money, rank)
	if not (saved and saved.items[itemID]) or (qty or 0) <= 0 then return end
	append("gone", time(), indexOf(me()), itemID, qty, reason, whole(money), rank or 0)
	onChange()
end

local function ensureCostCache()
	if costCache then return costCache end
	costCache = {}
	for _, craft in ipairs((Ledger.Analyze(saved))) do
		if craft.itemID and craft.kind == "craft" and craft.left > 0 then
			local bucket = costCache[craft.itemID]
			if not bucket then
				bucket = { list = {}, index = 1 }
				costCache[craft.itemID] = bucket
			end
			bucket.list[#bucket.list + 1] = craft
		end
	end
	return costCache
end

-- What one of an item you crafted cost to make, going by the oldest craft of it
-- with some left, and whether that cost isn't known. Nil when none is left on
-- record: then it wasn't one of your crafts. Consumes one unit from the cache.
local function costToMake(itemID)
	local bucket = ensureCostCache()[itemID]
	while bucket and bucket.index <= #bucket.list do
		local craft = bucket.list[bucket.index]
		if craft.left > 0 then
			local each = craft.cost / craft.qty
			local noCost = craft.noCost or false
			craft.left = craft.left - 1
			if craft.left <= 0 then bucket.index = bucket.index + 1 end
			return each, noCost
		end
		bucket.index = bucket.index + 1
	end
end

local function enchantingName()
	local get = C_TradeSkillUI.GetProfessionInfoBySkillLineID
	local ok, info = pcall(get or error, ENCHANTING)
	local name = ok and info and info.professionName
	return name and name ~= "" and name or "Enchanting"
end

-- You disenchanted something and got `loot` ({ { itemID, link, qty } ... }, see
-- Gone.lua). Each material is on record as a craft of it, and waits to sell like
-- any other. When what you disenchanted was a craft of yours (`sourceID`), that
-- one went into them as their material: what it cost to make is what they cost,
-- split by what each is worth. Anything else you disenchant cost nothing to make.
function Ledger.RecordDisenchant(sourceID, loot)
	if not saved or #loot == 0 then return end
	local t = time()
	local cost, unknown = 0, false
	if sourceID and saved.items[sourceID] then
		local each, noCost = costToMake(sourceID)
		if each then
			cost, unknown = each, noCost
			-- Counted at what it cost to make: the profit is all in what it gave.
			appendRaw("used", t, sourceID, 1, 1)
		end
	end
	local keep = ns.db.ahCut and (1 - ns.AH_CUT) or 1
	local worth, count = 0, 0
	for _, item in ipairs(loot) do
		local price = ns.Prices.Sale(item.link, item.itemID)
		item.unit = price and price * keep or 0
		worth = worth + item.unit * item.qty
		count = count + item.qty
	end
	local character, profession = indexOf(me()), indexOf(enchantingName())
	for _, item in ipairs(loot) do
		local share = worth > 0 and item.unit * item.qty / worth or item.qty / count
		local itemCost = cost * share
		local rank = rankOf(item.link, 0)
		saved.items[item.itemID] = saved.items[item.itemID] or nameIn(item.link)
		-- No forecasts: the panel had nothing to say about it.
		appendRaw("crafts", t, character, profession, Ledger.DISENCHANT, item.itemID, rank, item.qty, "craft",
			whole(item.unit), whole(itemCost), 0, whole(item.unit * item.qty - itemCost), "", "", unknown and 1 or 0)
		if costCache and item.qty > 0 then
			local bucket = costCache[item.itemID]
			if not bucket then
				bucket = { list = {}, index = 1 }
				costCache[item.itemID] = bucket
			end
			bucket.list[#bucket.list + 1] = {
				itemID = item.itemID, kind = "craft", qty = item.qty, left = item.qty,
				cost = whole(itemCost), noCost = unknown,
			}
		end
	end
	onChange()
end

-- Every item you've crafted: itemID -> its name. Not to be changed.
function Ledger.CraftedItems()
	return saved and saved.items or {}
end

-- What's on record as left of the crafts of the character you're on, but isn't
-- with it any more: not in its bags or banks, and not posted on the auction house
-- these last days. { { itemID, qty } ... }, and how many items that is.
function Ledger.Missing()
	if demo or not saved then return {}, 0 end
	local crafts, _, _, posts = Ledger.Analyze(saved)
	local mine, left, posted = me(), {}, {}
	for _, craft in ipairs(crafts) do
		if craft.character == mine and craft.left > 0 then left[craft.itemID] = (left[craft.itemID] or 0) + craft.left end
	end
	-- An auction that ran out or was cancelled comes back by mail, so one posted
	-- these last days counts whether or not it's still up.
	local now = time()
	local since = now - POST_DAYS * DAY
	for _, post in ipairs(posts) do
		if post.character == mine and post.t >= since and post.left > 0 then
			posted[post.itemID] = (posted[post.itemID] or 0) + post.left
		end
	end
	local snap = saved.live and saved.live[mine]
	local livePosted = {}
	for _, entry in ipairs(snap and snap.list or {}) do
		if (entry.qty or 0) > 0 and (not entry.expiresAt or now < entry.expiresAt) then
			livePosted[entry.itemID] = (livePosted[entry.itemID] or 0) + entry.qty
		end
	end
	local list, total = {}, 0
	for itemID, qty in pairs(left) do
		local have = ns.Model.Owned(itemID) + math.max(posted[itemID] or 0, livePosted[itemID] or 0)
		if qty > have then
			list[#list + 1] = { itemID = itemID, qty = qty - have }
			total = total + qty - have
		end
	end
	return list, total
end

-- Writes off what's left of your crafts: `list` is { { itemID, qty, rank } ... }
-- (see Ledger.Missing). They stop waiting to sell, with no profit or loss counted.
function Ledger.WriteOff(list)
	if demo or not saved then return end
	local t, character = time(), indexOf(me())
	for _, entry in ipairs(list) do
		if entry.qty > 0 and saved.items[entry.itemID] then
			append("gone", t, character, entry.itemID, entry.qty, "written", 0, entry.rank or 0)
		end
	end
	onChange()
end

-- Takes an item's write-offs back (scoped to `rank` when given): what was
-- written off of it is left again.
function Ledger.TakeBack(itemID, rank)
	if demo or not saved then return end
	costCache = nil
	local id = tostring(itemID)
	for _, day in pairs(saved.days) do
		if day.gone then
			local kept = {}
			for line in day.gone:gmatch("[^\n]+") do
				local fields = split(line)
				local lineRank = tonumber(fields[7]) or 0
				local sameRank = not rank or rank == 0 or lineRank == 0 or lineRank == rank
				if not (fields[3] == id and fields[5] == "written" and sameRank) then kept[#kept + 1] = line .. "\n" end
			end
			day.gone = #kept > 0 and table.concat(kept) or nil
		end
	end
	onChange()
end

-- Pending post captured at Post*/ConfirmPost* and committed once the server
-- confirms AUCTION_HOUSE_AUCTION_CREATED, plus debounced owned-auction refresh.
local pendingPost
local ownedReadThisVisit = false
local ownedRefreshQueued = false

local function requestOwnedSoon()
	if ownedRefreshQueued then return end
	ownedRefreshQueued = true
	C_Timer.After(1.0, function()
		ownedRefreshQueued = false
		if ns.AuctionSearch and ns.AuctionSearch.IsOpen and ns.AuctionSearch.IsOpen()
			and not (ns.PriceScan and ns.PriceScan.State and ns.PriceScan.State())
			and ns.AuctionSearch.Owned and ns.AuctionSearch.Waiting
			and ns.AuctionSearch.Waiting("ledger") == 0 then
			ns.AuctionSearch.Owned("ledger", nop)
		end
	end)
end

-- Resolves an auction post from an ItemLocation (handling missing hyperlinks
-- on commodities and bag-slot fallback).
local function buildPost(location, qty, unit, duration)
	if not (saved and location and unit and (qty or 0) > 0) then return end
	local ok, link = pcall(C_Item.GetItemLink, location)
	if not ok then link = nil end
	local itemID = link and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(link) or nil
	if (not link or not itemID) and location.GetBagAndSlot and C_Container and C_Container.GetContainerItemInfo then
		local okSlot, bag, slot = pcall(location.GetBagAndSlot, location)
		local info = okSlot and bag and C_Container.GetContainerItemInfo(bag, slot)
		if info then
			link = link or info.hyperlink
			itemID = itemID or info.itemID
		end
	end
	if not itemID and C_Item.GetItemID then
		local okID, id = pcall(C_Item.GetItemID, location)
		if okID and id and id > 0 then itemID = id end
	end
	if not (itemID and saved.items[itemID]) then return end
	return {
		itemID = itemID,
		rank = rankOf(link or itemID),
		qty = qty,
		unit = whole(unit),
		name = nameIn(link) or saved.items[itemID],
		hours = POST_HOURS[duration] or MAX_POST_HOURS,
		at = GetTime(),
	}
end

-- Your auctions as the game last listed them, the ones not sold yet: auctionID ->
-- { itemID, qty, unit }, of your own crafts. Also updates `saved.live` for the
-- current character and backfills unseen auctions into `posts` once for future
-- mailbox sale rank matching.
local ownAuctions = {}

local function readOwnAuctions()
	ownedReadThisVisit = true
	wipe(ownAuctions)
	local now = time()
	saved.live = saved.live or {}
	saved.seenAuctions = saved.seenAuctions or {}
	for id, exp in pairs(saved.seenAuctions) do
		if type(exp) ~= "number" or exp < now then saved.seenAuctions[id] = nil end
	end

	local meKey = me()
	local liveList = {}
	for index = 1, C_AuctionHouse.GetNumOwnedAuctions() do
		local info = C_AuctionHouse.GetOwnedAuctionInfo(index)
		local itemID = info and info.itemKey and info.itemKey.itemID
		local sold = Enum.AuctionStatus and info.status == Enum.AuctionStatus.Sold
		if itemID and saved.items[itemID] and not sold and (info.quantity or 0) > 0 then
			local qty = info.quantity or 1
			local unit = whole(info.buyoutAmount or info.bidAmount or 0)
			local rank = rankOf(info.itemLink or itemID)
			local secs = info.timeLeftSeconds or MAX_POST_HOURS * 3600
			local expiresAt = now + secs
			if info.auctionID then
				ownAuctions[info.auctionID] = { itemID = itemID, qty = qty, unit = unit }
			end
			liveList[#liveList + 1] = {
				id = info.auctionID,
				itemID = itemID,
				rank = rank,
				qty = qty,
				unit = unit,
				expiresAt = expiresAt,
			}
			if info.auctionID and not saved.seenAuctions[info.auctionID] then
				saved.seenAuctions[info.auctionID] = expiresAt
				local hours = math.max(math.ceil(secs / 3600), 1)
				append("posts", math.max(now - 60, 0), indexOf(meKey), itemID, rank, qty, unit,
					nameIn(info.itemLink) or saved.items[itemID], hours)
			end
		end
	end
	saved.live[meKey] = { at = now, list = liveList }
	onChange()
end

-- Commits a captured post once the auction house confirms creation, and schedules
-- a synced refresh so unhooked addon posts (e.g. Auctionator) also appear.
local function onAuctionCreated(auctionID)
	if not saved then return end
	if pendingPost and (GetTime() - pendingPost.at) <= 10 then
		local p = pendingPost
		pendingPost = nil
		local now = time()
		local meKey = me()
		append("posts", now, indexOf(meKey), p.itemID, p.rank, p.qty, p.unit, p.name, p.hours)
		local expiresAt = now + p.hours * 3600
		if auctionID then
			saved.seenAuctions = saved.seenAuctions or {}
			saved.seenAuctions[auctionID] = expiresAt
			ownAuctions[auctionID] = { itemID = p.itemID, qty = p.qty, unit = p.unit }
		end
		if saved.live and saved.live[meKey] then
			saved.live[meKey].at = now
			saved.live[meKey].list = saved.live[meKey].list or {}
			saved.live[meKey].list[#saved.live[meKey].list + 1] = {
				id = auctionID,
				itemID = p.itemID,
				rank = p.rank,
				qty = p.qty,
				unit = p.unit,
				expiresAt = expiresAt,
			}
		end
		onChange()
	end
	ownedReadThisVisit = false
	requestOwnedSoon()
end

-- You cancelled an auction: it isn't on the auction house any more.
local function recordCancel(auctionID)
	local auction = auctionID and ownAuctions[auctionID]
	if saved then
		local snap = saved.live and saved.live[me()]
		if snap and snap.list and auctionID then
			for i = #snap.list, 1, -1 do
				if snap.list[i].id == auctionID then
					table.remove(snap.list, i)
					break
				end
			end
		end
	end
	if not (saved and auction) then return end
	ownAuctions[auctionID] = nil
	append("pulled", time(), indexOf(me()), auction.itemID, auction.qty, whole(auction.unit))
	onChange()
end

-- Something you bought. `spent` is the gold it took; nil leaves it out.
local function recordBought(itemID, link, qty, spent, source)
	if not (saved and itemID and spent and spent > 0 and (qty or 0) > 0) then return end
	append("bought", time(), indexOf(me()), itemID, rankOf(link or itemID), qty, whole(spent),
		whole(ns.Prices.Buy(itemID)), source, nameIn(link) or C_Item.GetItemNameByID(itemID) or "?")
	onChange()
end

-- The commodity purchase under way: { itemID, qty, total }. The game names the
-- price in between starting it and confirming it.
local commodity
-- Single items you bid on: auctionID -> { link, itemID, amount }, until they're won.
local bids = {}

local function watchPurchases(events)
	if not C_AuctionHouse then return end
	hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(itemID, qty)
		commodity = { itemID = itemID, qty = qty }
	end)
	hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, qty)
		if commodity and commodity.itemID == itemID then commodity.qty = qty end
	end)
	hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, amount)
		local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, auctionID)
		local link = ok and info and info.itemLink
		local itemID = link and C_Item.GetItemInfoInstant(link) or (ok and info and info.itemKey and info.itemKey.itemID)
		if itemID then bids[auctionID] = { link = link, itemID = itemID, amount = amount } end
	end)
	events:RegisterEvent("COMMODITY_PRICE_UPDATED")
	events:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
	events:RegisterEvent("COMMODITY_PURCHASE_FAILED")
	events:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED")

	hooksecurefunc("BuyMerchantItem", function(index, qty)
		local info = C_MerchantFrame.GetItemInfo(index)
		local link = GetMerchantItemLink(index)
		if not (info and link) or info.hasExtendedCost or info.price <= 0 then return end
		-- Only materials: what a vendor sells otherwise has nothing to do with crafting.
		local itemID, _, _, _, _, classID = C_Item.GetItemInfoInstant(link)
		if classID ~= Enum.ItemClass.Tradegoods then return end
		local stack = math.max(info.stackCount, 1)
		qty = qty or stack
		recordBought(itemID, link, qty, info.price / stack * qty, "vendor")
	end)
end

local function onPurchaseEvent(event, ...)
	if event == "COMMODITY_PRICE_UPDATED" then
		local _, total = ...
		if commodity then commodity.total = total end
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		if commodity then recordBought(commodity.itemID, nil, commodity.qty, commodity.total, "auction") end
		commodity = nil
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		commodity = nil
	else
		local auctionID = ...
		local bid = bids[auctionID]
		if bid then recordBought(bid.itemID, bid.link, 1, bid.amount, "auction") end
		bids[auctionID] = nil
	end
end

local function watchPosts()
	if not C_AuctionHouse then return end
	if C_AuctionHouse.PostItem then
		hooksecurefunc(C_AuctionHouse, "PostItem", function(location, duration, qty, bid, buyout)
			pendingPost = buildPost(location, qty, buyout or bid, duration)
		end)
	end
	if C_AuctionHouse.PostCommodity then
		hooksecurefunc(C_AuctionHouse, "PostCommodity", function(location, duration, qty, unit)
			pendingPost = buildPost(location, qty, unit, duration)
		end)
	end
	if C_AuctionHouse.ConfirmPostItem then
		hooksecurefunc(C_AuctionHouse, "ConfirmPostItem", function(location, duration, qty, bid, buyout)
			local p = buildPost(location, qty, buyout or bid, duration)
			if p then pendingPost = p elseif pendingPost then pendingPost.at = GetTime() end
		end)
	end
	if C_AuctionHouse.ConfirmPostCommodity then
		hooksecurefunc(C_AuctionHouse, "ConfirmPostCommodity", function(location, duration, qty, unit)
			local p = buildPost(location, qty, unit, duration)
			if p then pendingPost = p elseif pendingPost then pendingPost.at = GetTime() end
		end)
	end
end

---------------------------------------------------------------------------
-- Keeping it small
---------------------------------------------------------------------------

-- Days past KEEP_DAYS become their month's totals; `now` is today's time. Profit is
-- what each craft had made by then: its sales go with it, so it's worked out first.
function Ledger.RollUp(db, now)
	local oldest = dayOf(now) - KEEP_DAYS
	local due = false
	for day in pairs(db.days) do
		if day < oldest then
			due = true
			break
		end
	end
	if not due then return end

	local function totalsOf(t)
		local month = date("%Y-%m", t)
		local totals = db.months[month]
		if not totals then
			totals = { crafts = 0, items = 0, cost = 0, profit = 0, spent = 0 }
			db.months[month] = totals
		end
		return totals
	end
	local crafts, _, bought = Ledger.Analyze(db)
	for _, craft in ipairs(crafts) do
		if dayOf(craft.t) < oldest then
			local totals = totalsOf(craft.t)
			totals.crafts = totals.crafts + 1
			totals.items = totals.items + craft.qty
			totals.cost = totals.cost + craft.cost
			totals.profit = totals.profit + whole(craft.earned)
		end
	end
	for _, entry in ipairs(bought) do
		if dayOf(entry.t) < oldest then
			local totals = totalsOf(entry.t)
			totals.spent = totals.spent + entry.spent
		end
	end
	for day in pairs(db.days) do
		if day < oldest then db.days[day] = nil end
	end
	for auctionID, expiresAt in pairs(db.seenAuctions or {}) do
		if type(expiresAt) ~= "number" or expiresAt < now then db.seenAuctions[auctionID] = nil end
	end
	for character, snap in pairs(db.live or {}) do
		if type(snap) == "table" and type(snap.list) == "table" then
			local kept = {}
			for _, entry in ipairs(snap.list) do
				if (entry.qty or 0) > 0 and (not entry.expiresAt or now < entry.expiresAt) then
					kept[#kept + 1] = entry
				end
			end
			if #kept > 0 then snap.list = kept else db.live[character] = nil end
		else
			db.live[character] = nil
		end
	end
	if db == saved then costCache = nil end
end

-- The months past KEEP_DAYS, newest first: { month ("2026-08"), crafts, items, cost,
-- profit, spent }.
function Ledger.Months()
	local records = demo or saved
	local list = {}
	for month, totals in pairs(records and records.months or {}) do
		list[#list + 1] = { month = month, crafts = totals.crafts, items = totals.items, cost = totals.cost,
			profit = totals.profit, spent = totals.spent }
	end
	table.sort(list, function(a, b) return a.month > b.month end)
	return list
end

-- Forgets every record, for all your characters. Sales from before stay out: seeded
-- stays set, so what the mailbox told us doesn't come back.
function Ledger.Clear()
	saved.names, saved.items, saved.days, saved.months, saved.live, saved.seenAuctions = {}, {}, {}, {}, {}, {}
	wipe(nameIndex)
	wipe(ownAuctions)
	costCache = nil
	onChange()
end

-- An item's name, from the game or from when you crafted it.
function Ledger.ItemName(itemID)
	local records = demo or saved
	return (records and records.items[itemID]) or C_Item.GetItemNameByID(itemID) or "?"
end

-- Everything for the Ledger window, unpacked (see Ledger.Analyze).
function Ledger.Load()
	if demo or saved then return Ledger.Analyze(demo or saved) end
	return {}, { qty = 0, money = 0 }, {}
end

-- Turns the made-up records on or off, and says which. Nothing of it is saved.
function Ledger.ToggleDemo()
	if demo then
		demo = nil
		return false
	end
	local names = { "Demo-Realm", "Demoalt-Realm", "Tailoring", "Alchemy" }
	local items = {
		{ 2996, "Bolt of Linen Cloth", 3, 500000, 2500000, 60 }, -- itemID, name, profession, worth, cost, how often it sells
		{ 2997, "Bolt of Woolen Cloth", 3, 1200000, 900000, 95 },
		{ 118, "Minor Healing Potion", 4, 300000, 1200000, 30 },
	}
	demo = { names = names, items = {}, days = {}, months = {} }
	local now = time()
	local function add(t, list, ...)
		local day = demo.days[dayOf(t)] or {}
		demo.days[dayOf(t)] = day
		day[list] = (day[list] or "") .. table.concat({ t, ... }, SEP) .. "\n"
	end
	for back = 1, 40 do
		local t = now - back * DAY
		for index, item in ipairs(items) do
			demo.items[item[1]] = item[2]
			local qty = 10
			add(t, "crafts", index % 2 + 1, item[3], 0, item[1], 0, qty, "craft", item[4], item[5],
				item[4] * qty - item[5], item[4] * qty - item[5])
			-- Sells later, for a bit less the more often it sells.
			if back > 2 and (back * 10 + index * 7) % 100 < item[6] then
				local sold = t + 2 * DAY
				local price = math.floor(item[4] * (0.75 + (back % 5) * 0.08))
				add(sold, "sales", 1, item[2], qty, price * qty, math.floor(price / 0.95))
			end
		end
		if back % 3 == 0 then add(t, "crafts", 1, 3, 0, 2996, 0, 1, "patron", 0, 800000, 5000000, 4200000) end
		if back % 7 == 0 then add(t, "crafts", 2, 4, 0, 118, 0, 1, "personal", 0, 300000, 1000000, 1000000) end
		add(t, "bought", 1, 2589, 0, 20, 400000 + back * 3000, 21000, "auction", "Linen Cloth")
		if back % 4 == 0 then add(t, "bought", 2, 2320, 0, 5, 50000, 12000, "vendor", "Coarse Thread") end
		-- Some potions get drunk, and now and then a few bolts go to a vendor.
		if back % 5 == 0 then add(t + DAY / 2, "gone", 1, 118, 3, "used", 0, 0) end
		if back % 9 == 0 then add(t + DAY / 2, "gone", 1, 2996, 2, "vendor", 2 * 40000, 0) end
	end
	return true
end

function Ledger.Init()
	CraftonomicsDB.ledger = CraftonomicsDB.ledger or { names = {}, items = {}, days = {}, months = {} }
	saved = CraftonomicsDB.ledger
	saved.live = saved.live or {}
	saved.seenAuctions = saved.seenAuctions or {}
	costCache = nil
	for index, name in ipairs(saved.names) do nameIndex[name] = index end
	watchPosts()
	local events = CreateFrame("Frame")
	watchPurchases(events)
	events:RegisterEvent("PLAYER_LOGIN")
	-- Guarded: not every version of the game has these.
	pcall(events.RegisterEvent, events, "OWNED_AUCTIONS_UPDATED")
	pcall(events.RegisterEvent, events, "AUCTION_CANCELED")
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_AUCTION_CREATED")
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_SHOW")
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_CLOSED")
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "OWNED_AUCTIONS_UPDATED" then
			pcall(readOwnAuctions)
			return
		elseif event == "AUCTION_CANCELED" then
			recordCancel((...))
			return
		elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
			onAuctionCreated((...))
			return
		elseif event == "AUCTION_HOUSE_SHOW" then
			ownedReadThisVisit = false
			C_Timer.After(1.5, function()
				if not ownedReadThisVisit then requestOwnedSoon() end
			end)
			return
		elseif event == "AUCTION_HOUSE_CLOSED" then
			pendingPost, ownedReadThisVisit = nil, false
			if ns.AuctionSearch and ns.AuctionSearch.Drop then ns.AuctionSearch.Drop("ledger") end
			return
		end
		if event ~= "PLAYER_LOGIN" then
			onPurchaseEvent(event, ...)
			return
		end
		Ledger.RollUp(saved, time())
		-- The sales the mailbox already told us about count from the start.
		if not saved.seeded then
			saved.seeded = true
			for _, sale in ipairs(CraftonomicsDB.sales and CraftonomicsDB.sales.list or {}) do Ledger.RecordSale(sale) end
		end
	end)
end
