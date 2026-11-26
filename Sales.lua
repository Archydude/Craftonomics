-- Craftonomics: what your characters sold on the auction house, for the Best
-- crafts list's "You sold" column. Read from the "Auction successful" mail each
-- time the mailbox shows it, so a sale counts whether or not you take the gold.
local _, ns = ...

local Sales = {}
ns.Sales = Sales

-- Sales older than this many days aren't counted for the list.
Sales.DAYS = 14
-- Outcomes (sold + expired) older than this many days aren't counted for personal sale rate.
Sales.RATE_DAYS = 60
-- Minimum finished auctions (sold + expired) before personal sale rate drives automated decisions.
Sales.MIN_DECISION_SAMPLES = 3
-- A sale or expired auction mail lives this many days, so its daysLeft says when it came. Sales are
-- kept that long too: a mail read late still reaches the Ledger, and one that's
-- still in the mailbox isn't taken for a new sale.
local MAIL_DAYS = 30
-- Seconds two readings of the same mail may differ by.
local SAME_MAIL = 300
local DAY = 86400
local format = string.format

local EXPIRED_PATTERN = "^" .. (_G.AUCTION_EXPIRED_MAIL_SUBJECT or "Auction expired: %s")
	:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
	:gsub("%%%%s", "(.+)") .. "$"

-- CraftonomicsDB.sales = {
--   since = when Craftonomics started counting (time()),
--   list = { { name, qty, money, t } ... }, every sale in the last MAIL_DAYS days,
--   wide = when sales started being kept for MAIL_DAYS, not DAYS (time()),
--   rateSince = when Craftonomics started counting personal sale rates (sold + expired together),
--   expired = { { name, qty, t } ... }, every expired auction in the last MAIL_DAYS days,
--   rateDays = { [day] = "itemName\tsold\texpired\n..." }, daily outcomes over RATE_DAYS,
-- }
local saved
-- How many of each item were sold (name -> qty), so the Best crafts list doesn't
-- go through every sale for each row; and the time it's good until (when the
-- oldest sale in it gets too old to count). Worked out again after that, or when
-- a sale comes in.
local totals, totalsUntil
local rateTotals, rateTotalsDay, rateHasAny

local function dayOf(t)
	return math.floor(t / DAY)
end

function Sales.Init()
	CraftonomicsDB.sales = CraftonomicsDB.sales or { since = time(), list = {} }
	saved = CraftonomicsDB.sales
	saved.wide = saved.wide or time()
	saved.expired = saved.expired or {}
	saved.rateDays = saved.rateDays or {}
	saved.rateSince = saved.rateSince or (#saved.list == 0 and saved.since or time())
	totals, totalsUntil = nil, nil
	rateTotals, rateTotalsDay, rateHasAny = nil, nil, nil
end

-- The oldest sale a mail is read for. Mail older than DAYS when sales started
-- being kept longer may have been counted and dropped already, so it stays out.
local function oldestRead()
	return math.max(time() - (MAIL_DAYS + 1) * DAY, saved.wide - Sales.DAYS * DAY)
end

local function addRateOutcome(t, name, soldDelta, expiredDelta)
	if not (saved and name and name ~= "" and t) then return end
	if t < (saved.rateSince or 0) - SAME_MAIL then return end
	local day = dayOf(t)
	local map = {}
	local text = saved.rateDays[day]
	if type(text) == "string" then
		for itemName, sold, expired in text:gmatch("([^\t\n]+)\t(%d+)\t(%d+)") do
			map[itemName] = { tonumber(sold) or 0, tonumber(expired) or 0 }
		end
	end
	local entry = map[name]
	if not entry then
		entry = { 0, 0 }
		map[name] = entry
	end
	entry[1] = entry[1] + (soldDelta or 0)
	entry[2] = entry[2] + (expiredDelta or 0)
	local names = {}
	for itemName in pairs(map) do names[#names + 1] = itemName end
	table.sort(names)
	local lines = {}
	for _, itemName in ipairs(names) do
		local counts = map[itemName]
		lines[#lines + 1] = format("%s\t%d\t%d", itemName, counts[1], counts[2])
	end
	saved.rateDays[day] = table.concat(lines, "\n")
	rateTotals, rateTotalsDay, rateHasAny = nil, nil, nil
end

local function prune()
	local cutoff = time() - (MAIL_DAYS + 1) * DAY
	local kept = {}
	for _, sale in ipairs(saved.list) do
		if sale.t >= cutoff then kept[#kept + 1] = sale end
	end
	saved.list = kept
	local keptExp = {}
	for _, exp in ipairs(saved.expired or {}) do
		if exp.t >= cutoff then keptExp[#keptExp + 1] = exp end
	end
	saved.expired = keptExp
	local dayCutoff = dayOf(time()) - Sales.RATE_DAYS + 1
	for day in pairs(saved.rateDays or {}) do
		if day < dayCutoff then saved.rateDays[day] = nil end
	end
	totals, rateTotals, rateTotalsDay, rateHasAny = nil, nil, nil, nil
end

-- The "Auction successful" mails in the inbox: { { name, qty, money, t } ... }.
local function inboxSales()
	local list = {}
	local now = time()
	for index = 1, GetInboxNumItems() do
		local invoiceType, itemName, _, bid, _, _, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
		if invoiceType == "seller" and itemName then
			local daysLeft = select(7, GetInboxHeaderInfo(index))
			if daysLeft then
				list[#list + 1] = { name = itemName, qty = count or 1, money = bid or 0, net = (bid or 0) - (consignment or 0),
					t = now + (daysLeft - MAIL_DAYS) * DAY }
			end
		end
	end
	return list
end

-- The "Auction expired" mails in the inbox (cancelled mails use a different subject and are ignored).
local function inboxExpired()
	local list = {}
	local now = time()
	for index = 1, GetInboxNumItems() do
		if not GetInboxInvoiceInfo(index) then
			local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(index)
			local matchedName = type(subject) == "string" and daysLeft and subject:match(EXPIRED_PATTERN)
			if matchedName then
				local getInboxItem = _G.GetInboxItem
				local itemName, count
				if getInboxItem then
					local name, _, _, stack = getInboxItem(index, 1)
					itemName, count = name, stack
				end
				if not itemName or itemName == "" then
					local baseName, stackCount = matchedName:match("^(.-)%s*%((%d+)%)$")
					if baseName then
						itemName, count = baseName, tonumber(stackCount)
					else
						itemName, count = matchedName, 1
					end
				end
				list[#list + 1] = {
					name = itemName,
					qty = math.max(tonumber(count) or 1, 1),
					t = now + (daysLeft - MAIL_DAYS) * DAY,
				}
			end
		end
	end
	return list
end

-- Adds the inbox's sales and expired auctions that aren't saved yet. A mail that's still there from
-- last time matches the saved record with the same item, amount (and gold for sales) that came
-- at the same time; each saved record matches one mail, so identical mails stay apart.
local function record()
	if not saved then return end
	prune()
	local cutoff = oldestRead()
	local rateChanged = false
	local matched = {}
	for _, sale in ipairs(inboxSales()) do
		if sale.t >= cutoff then
			local found = false
			for i, old in ipairs(saved.list) do
				if not matched[i] and old.name == sale.name and old.qty == sale.qty and old.money == sale.money
					and math.abs(old.t - sale.t) <= SAME_MAIL then
					matched[i], found = true, true
					break
				end
			end
			if not found then
				saved.list[#saved.list + 1] = sale
				matched[#saved.list] = true
				totals = nil
				addRateOutcome(sale.t, sale.name, sale.qty, 0)
				rateChanged = true
				if ns.Ledger and ns.Ledger.RecordSale then ns.Ledger.RecordSale(sale) end
			end
		end
	end
	local expCutoff = math.max(time() - (MAIL_DAYS + 1) * DAY, (saved.rateSince or 0) - SAME_MAIL)
	local matchedExp = {}
	for _, exp in ipairs(inboxExpired()) do
		if exp.t >= expCutoff then
			local found = false
			for i, old in ipairs(saved.expired) do
				if not matchedExp[i] and old.name == exp.name and old.qty == exp.qty
					and math.abs(old.t - exp.t) <= SAME_MAIL then
					matchedExp[i], found = true, true
					break
				end
			end
			if not found then
				saved.expired[#saved.expired + 1] = exp
				matchedExp[#saved.expired] = true
				addRateOutcome(exp.t, exp.name, 0, exp.qty)
				rateChanged = true
			end
		end
	end
	if rateChanged then
		if ns.BestCrafts and ns.BestCrafts.Reprice then ns.BestCrafts.Reprice(true) end
		if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
		if ns.BestCraftsList and ns.BestCraftsList.Refresh then ns.BestCraftsList.Refresh() end
	end
end

-- How many of the item called `name` your characters sold in the last DAYS days.
function Sales.Sold(name)
	if not (saved and name) then return 0 end
	local now = time()
	if not totals or now > totalsUntil then
		totals, totalsUntil = {}, math.huge
		local cutoff = now - Sales.DAYS * DAY
		for _, sale in ipairs(saved.list) do
			if sale.t >= cutoff then
				totals[sale.name] = (totals[sale.name] or 0) + sale.qty
				totalsUntil = math.min(totalsUntil, sale.t + Sales.DAYS * DAY)
			end
		end
	end
	return totals[name] or 0
end

-- How many days of sales there are so far: DAYS, or fewer when Craftonomics
-- started counting more recently.
function Sales.DaysCounted()
	if not saved then return 0 end
	return math.min(Sales.DAYS, math.floor((time() - saved.since) / DAY))
end

local function ensureRateTotals()
	local todayDay = dayOf(time())
	if rateTotals and rateTotalsDay == todayDay then return end
	rateTotals, rateTotalsDay, rateHasAny = {}, todayDay, false
	local cutoff = todayDay - Sales.RATE_DAYS + 1
	for day, text in pairs(saved.rateDays or {}) do
		if day >= cutoff and type(text) == "string" then
			for itemName, sold, expired in text:gmatch("([^\t\n]+)\t(%d+)\t(%d+)") do
				local s, e = tonumber(sold) or 0, tonumber(expired) or 0
				if s + e > 0 then
					local entry = rateTotals[itemName]
					if not entry then
						entry = { sold = 0, expired = 0 }
						rateTotals[itemName] = entry
					end
					entry.sold = entry.sold + s
					entry.expired = entry.expired + e
					rateHasAny = true
				end
			end
		end
	end
end

-- Whether any finished auctions (sold + expired) are on record for personal sale rate.
function Sales.HasSaleRate()
	if not saved then return false end
	ensureRateTotals()
	return rateHasAny == true
end

-- Personal sale rate (0..1) for `name` over RATE_DAYS, plus sold and total (sold + expired) counts.
function Sales.SaleRate(name)
	if not (saved and name and name ~= "") then return end
	ensureRateTotals()
	local entry = rateTotals[name]
	if not entry then return end
	local total = entry.sold + entry.expired
	if total <= 0 then return end
	return entry.sold / total, entry.sold, total
end

-- The inbox changes in bursts while you take mail: read it right away, so a
-- mail taken at once still counts, then once more when the burst is over.
local queued = false
local events = CreateFrame("Frame")
events:RegisterEvent("MAIL_INBOX_UPDATE")
events:SetScript("OnEvent", function()
	if queued then return end
	queued = true
	record()
	C_Timer.After(0.5, function()
		queued = false
		record()
	end)
end)
