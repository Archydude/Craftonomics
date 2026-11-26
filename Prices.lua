-- Craftonomics: prices from TradeSkillMaster or Auctionator, TSM prices another
-- character saved when TSM isn't loaded here (see SavedPrices.lua), or Craft
-- Profit's own scan of the auction house (see PriceScan.lua).
local ADDON_NAME, ns = ...

local Prices = {}
ns.Prices = Prices

-- Whether the Price addon option lets TSM's prices in.
local function wantsTSM()
	return ns.db.provider == "auto" or ns.db.provider == "tsm" or ns.db.provider == "fresh"
end

local function tsmAvailable()
	return wantsTSM() and TSM_API and TSM_API.GetCustomPriceValue
end

-- Whether TSM's prices come from another character's save: TSM isn't loaded here.
local function savedPrices()
	return wantsTSM() and not (TSM_API and TSM_API.GetCustomPriceValue) and ns.SavedPrices.InUse()
end

local function auctionatorAPI()
	if ns.db.provider ~= "auto" and ns.db.provider ~= "auctionator" and ns.db.provider ~= "fresh" then return end
	return Auctionator and Auctionator.API and Auctionator.API.v1
end

-- Craftonomics' own scan: the last one asked with Automatic, so it prices what
-- nobody else does, and the only one when it's the Price addon picked.
local function ownScan()
	if ns.db.provider == "auto" or ns.db.provider == "own" or ns.db.provider == "fresh" then return ns.PriceScan end
end

-- TSM's price type for the lowest auction right now. A scan of the auction
-- house gives the same kind of price, so only for this type can TSM and a scan
-- stand in for each other.
local LOWEST = "dbminbuyout"

-- Other addons' APIs can change or throw on items they don't know, so every
-- call into them is guarded. A failed lookup is just "no price".
local function tsmValue(source, itemString)
	local ok, value = pcall(TSM_API.GetCustomPriceValue, source, itemString)
	if ok and value and value > 0 then return value end
end

local function auctionatorValue(fn, arg)
	if not fn then return end
	local ok, value = pcall(fn, ADDON_NAME, arg)
	if ok and value and value > 0 then return value end
end

-- Where Auctionator keeps the times of its scans: in its own saved state, not its
-- API, so a change on its side just means no answer.
local AUCTIONATOR_SCANS = { "TimeOfLastReplicateScan", "TimeOfLastBrowseScan", "TimeOfLastGetAllScan" }

-- When Auctionator last scanned the auction house (seconds since 1970), or nil.
local function auctionatorScanned()
	local state = Auctionator and Auctionator.SavedState
	if type(state) ~= "table" then return nil end
	local last = 0
	for _, key in ipairs(AUCTIONATOR_SCANS) do
		if type(state[key]) == "number" and state[key] > last then last = state[key] end
	end
	return last > 0 and last or nil
end

---------------------------------------------------------------------------
-- The freshest prices
---------------------------------------------------------------------------

-- What each source is called in the footer.
local FRESH_NAMES = { tsm = "TSM", own = "Craftonomics' scan", auctionator = "Auctionator's scan" }
-- The sources newest first, and when that was worked out (see freshest).
local freshList, freshAt

-- With "Freshest prices" as the Price addon: who has prices, newest first:
-- { { name = "tsm" | "own" | "auctionator", seconds = how old its prices are } ... }.
-- TSM's are as old as its desktop app's last download, a scan's as old as the
-- scan. Worked out again at most once a second. Nil when the choice isn't on, on
-- an alt using saved TSM prices, and when TSM is loaded but doesn't say how old
-- its prices are: prices then come as with Automatic.
local function freshest()
	if ns.db.provider ~= "fresh" or savedPrices() then return end
	local now = GetTime()
	if freshAt and now - freshAt < 1 then return freshList or nil end
	freshAt, freshList = now, false
	local list = {}
	if TSM_API and TSM_API.GetCustomPriceValue then
		local downloaded = ns.SavedPrices.TSMDownloaded()
		if not downloaded then return end
		list[#list + 1] = { name = "tsm", seconds = math.max(time() - downloaded, 0) }
	end
	local scanned = ns.PriceScan.Seconds()
	if scanned then list[#list + 1] = { name = "own", seconds = scanned } end
	local auctionator = Auctionator and Auctionator.API and Auctionator.API.v1 and auctionatorScanned()
	if auctionator then list[#list + 1] = { name = "auctionator", seconds = math.max(time() - auctionator, 0), at = auctionator } end
	table.sort(list, function(a, b) return a.seconds < b.seconds end)
	freshList = list
	return list
end

-- That list for a price of TSM's type `source` (the one picked for materials, or
-- for crafted items). With TSM loaded, only its lowest auction is a price a scan
-- can stand in for; any other type prices as with Automatic.
local function freshFor(source)
	local list = freshest()
	if not list or #list == 0 then return end
	if TSM_API and TSM_API.GetCustomPriceValue and source ~= LOWEST then return end
	return list
end

-- Whether Auctionator saw the item in its last scan, going by how many days ago
-- it last saw it (`ageOf` is its function for that) and when that scan ran.
-- Comparing day buckets avoids rejecting a fresh scan taken right before rollover.
local function auctionatorSaw(ageOf, arg, source)
	if not ageOf then return false end
	local ok, age = pcall(ageOf, ADDON_NAME, arg)
	if not (ok and type(age) == "number") then return false end
	local dayZero = Auctionator and Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
	if dayZero and source.at then
		local today = math.floor((time() - dayZero) / 86400)
		local scanDay = math.floor((source.at - dayZero) / 86400)
		return age <= math.max(today - scanDay, 0)
	end
	return age <= math.ceil(source.seconds / 86400)
end

-- A material's price from the freshest source that has it, and which that is. A
-- scan only counts for what it saw up for sale: an item nobody had up keeps an
-- older price there. Nil when none has it that fresh.
local function freshMaterial(itemID)
	local list = freshFor(ns.db.matSource)
	if not list then return end
	-- Looked up by itself since the newest of them: nothing is fresher than that.
	local checked = ns.PriceScan.MaterialChecked(itemID)
	if checked and checked <= list[1].seconds then
		local value = ns.PriceScan.Material(itemID)
		if value then return value, "own" end
	end
	for _, source in ipairs(list) do
		local value
		if source.name == "tsm" then
			value = tsmValue(ns.db.matSource, "i:" .. itemID)
		elseif source.name == "own" then
			value = ns.PriceScan.MaterialInLastScan(itemID) and ns.PriceScan.Material(itemID)
		else
			local api = Auctionator.API.v1
			value = auctionatorSaw(api.GetAuctionAgeByItemID, itemID, source)
				and auctionatorValue(api.GetAuctionPriceByItemID, itemID)
		end
		if value then return value, source.name end
	end
end

-- The same for a crafted item, by its link. `tsmSource` is TSM's price type to
-- go by: the one picked for crafted items unless given.
local function freshSale(link, itemID, tsmSource)
	tsmSource = tsmSource or ns.db.saleSource
	local list = freshFor(tsmSource)
	if not list then return end
	local checked = ns.PriceScan.SaleChecked(link, itemID)
	if checked and checked <= list[1].seconds then
		local value = ns.PriceScan.Sale(link, itemID)
		if value then return value, "own" end
	end
	for _, source in ipairs(list) do
		local value
		if source.name == "tsm" then
			local ok, itemString = pcall(TSM_API.ToItemString, link)
			value = ok and itemString and tsmValue(tsmSource, itemString)
		elseif source.name == "own" then
			value = ns.PriceScan.SaleInLastScan(link, itemID) and ns.PriceScan.Sale(link, itemID)
		else
			local api = Auctionator.API.v1
			value = auctionatorSaw(api.GetAuctionAgeByItemLink, link, source)
				and auctionatorValue(api.GetAuctionPriceByItemLink, link)
		end
		if value then return value, source.name end
	end
end

-- What a vendor sells an item for, in copper (nil if no vendor sells it, or
-- nobody knows). On WoW Forever, common reagents (thread, flux, vials...) are
-- known before a price addon has seen a vendor sell them (Data\Forever.lua).
function Prices.Vendor(itemID)
	local api, own = auctionatorAPI(), ownScan()
	return (tsmAvailable() and tsmValue("vendorbuy", "i:" .. itemID))
		or (savedPrices() and ns.SavedPrices.Vendor(itemID))
		or (api and auctionatorValue(api.GetVendorPriceByItemID, itemID))
		or (own and own.Vendor(itemID))
		or (ns.VENDOR_PRICES and ns.VENDOR_PRICES[itemID])
		-- Price addons may not know vellums, and a vendor always has them.
		or (itemID == ns.VELLUM_ITEM and ns.VELLUM_PRICE or nil)
end

-- What a material costs you, in copper (nil if nobody knows): what it costs to
-- buy, or what crafting it costs when the crafting strategy crafts it (WoW
-- Forever's Craft myself and Cheapest way, see Chains.lua).
function Prices.Material(itemID)
	return ns.Chains.Cost(itemID) or Prices.Buy(itemID)
end

-- With both Auctionator's prices and Craftonomics' scan in use, whether the
-- scan's come first: the "Price with" choice. Either way the other one prices
-- what the first doesn't.
local function ownFirst()
	return ns.db.ahPrice == "own"
end

-- What a material costs on the auction house, in copper (nil if nobody knows).
local function auctionPrice(itemID)
	local api, own = auctionatorAPI(), ownScan()
	-- Freshest prices: the newest source that has it. Failing that, as with Automatic.
	local fresh = freshMaterial(itemID)
	if fresh then return fresh end
	local value = (tsmAvailable() and tsmValue(ns.db.matSource, "i:" .. itemID))
		or (savedPrices() and ns.SavedPrices.Material(itemID))
	if value then return value end
	if ownFirst() then
		return (own and own.Material(itemID)) or (api and auctionatorValue(api.GetAuctionPriceByItemID, itemID)) or nil
	end
	return (api and auctionatorValue(api.GetAuctionPriceByItemID, itemID)) or (own and own.Material(itemID)) or nil
end

-- Whether materials a vendor sells are bought from a vendor: unless "Buy vendor
-- items on the auction house" is on.
function Prices.BuysAtVendor(itemID)
	return not ns.db.vendorOnAH and Prices.Vendor(itemID) ~= nil
end

-- What buying a material costs, in copper (nil if nobody knows), whatever the
-- crafting strategy. Vendor-sold things (vials, thread...) cost the vendor price,
-- or with "Buy vendor items on the auction house", their auction price (the
-- vendor's while the auction house has none).
function Prices.Buy(itemID)
	local vendor = Prices.Vendor(itemID)
	if vendor and not ns.db.vendorOnAH then return vendor end
	return auctionPrice(itemID) or vendor
end

-- With "Buy vendor items on the auction house" on: when the auction house asks
-- more for a material than a vendor does, both prices. Nil otherwise.
function Prices.VendorCheaper(itemID)
	if not ns.db.vendorOnAH then return end
	local vendor = Prices.Vendor(itemID)
	local auction = vendor and auctionPrice(itemID)
	if auction and auction > vendor then return vendor, auction end
end

-- What a crafted item sells for, in copper, and where that price came from:
-- "tsm", "saved" (TSM prices saved for alts), "auctionator" or "own" (Craft
-- Profit's scan). Uses the full link so quality and item level count.
function Prices.SaleFrom(link, itemID)
	-- Freshest prices: the newest source that has it. Failing that, as with Automatic.
	local fresh, from = freshSale(link, itemID)
	if fresh then return fresh, from end
	if tsmAvailable() then
		local ok, itemString = pcall(TSM_API.ToItemString, link)
		local value = ok and itemString and tsmValue(ns.db.saleSource, itemString)
		if value then return value, "tsm" end
	elseif savedPrices() then
		local value = ns.SavedPrices.Sale(link, itemID)
		if value then return value, "saved" end
	end
	local api, own = auctionatorAPI(), ownScan()
	-- Craftonomics' scan before Auctionator's prices when that's the choice.
	local value = own and ownFirst() and own.Sale(link, itemID)
	if value then return value, "own" end
	if api then
		value = auctionatorValue(api.GetAuctionPriceByItemLink, link)
			or (itemID and auctionatorValue(api.GetAuctionPriceByItemID, itemID))
		if value then return value, "auctionator" end
	end
	value = own and own.Sale(link, itemID)
	if value then return value, "own" end
end

-- What a crafted item sells for, in copper (see Prices.SaleFrom).
function Prices.Sale(link, itemID)
	return (Prices.SaleFrom(link, itemID))
end

-- What disenchanting an item gives on average, in copper, and whose number it
-- is: "tsm" or "auctionator". Only uncommon to epic weapons and armor can be
-- disenchanted (TSM's number for anything else is what milling or prospecting
-- it gives). Nil for the rest, without either addon, and when neither can price
-- what it gives. Uses the full link so the item's level counts.
function Prices.Disenchant(link)
	local classID = link and select(6, C_Item.GetItemInfoInstant(link))
	if classID ~= Enum.ItemClass.Weapon and classID ~= Enum.ItemClass.Armor then return end
	local quality = C_Item.GetItemQualityByID(link)
	if not quality or quality < Enum.ItemQuality.Uncommon or quality > Enum.ItemQuality.Epic then return end
	if tsmAvailable() then
		local ok, itemString = pcall(TSM_API.ToItemString, link)
		local value = ok and itemString and tsmValue("destroy", itemString)
		if value then return value, "tsm" end
	end
	local api = auctionatorAPI()
	local value = api and auctionatorValue(api.GetDisenchantPriceByItemLink, link)
	if value then return value, "auctionator" end
end

-- What an item disenchants into, from Craftonomics' own table (ns.DISENCHANTS,
-- WoW Forever only), as lines like "80%  1-2 Strange Dust". Nil without a row for
-- the item's kind, quality and level.
local function ownDisenchants(link)
	local classID = ns.DISENCHANTS and select(6, C_Item.GetItemInfoInstant(link))
	local byQuality = classID and ns.DISENCHANTS[classID]
	local rows = byQuality and byQuality[C_Item.GetItemQualityByID(link) or 0]
	local level = rows and (C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo)(link)
	if not level then return end
	for _, row in ipairs(rows) do
		if level >= row[1] and level <= row[2] then
			local lines = {}
			for index = 3, #row do
				local chance, fewest, most, itemID = unpack(row[index])
				local name = ns.Format.ItemName(itemID)
				if name then
					name = ns.Format.RarityColored(itemID, name)
				else
					C_Item.RequestLoadItemDataByID(itemID)
					name = "Loading..."
				end
				lines[#lines + 1] = string.format("|cffffffff%s%%|r  %s %s", tostring(chance),
					fewest == most and tostring(fewest) or (fewest .. "-" .. most), name)
			end
			return lines
		end
	end
end

-- What an item disenchants into, as lines like "80%  1-2 Strange Dust": the
-- chance of each material and how many it gives. From Craftonomics' own table on
-- WoW Forever; for what that doesn't have, from Auctionator, which lists it
-- where it shows it on its own tooltips. That isn't part of Auctionator's API,
-- so a change on its side just means no list. Nil when neither has it.
function Prices.DisenchantsInto(link)
	local own = ownDisenchants(link)
	if own then return own end
	local list = Auctionator and Auctionator.Enchant and Auctionator.Enchant.GetDisenchantBreakdown
	if not list then return end
	local info = { C_Item.GetItemInfo(link) }
	if #info == 0 then return end
	local ok, lines = pcall(list, link, info)
	if not ok or type(lines) ~= "table" then return end
	local found = {}
	for _, line in ipairs(lines) do
		if type(line) == "string" then found[#found + 1] = strtrim(line) end
	end
	return #found > 0 and found or nil
end

-- Caps each rank's sale price at the price of every rank above it: nobody pays
-- more for rank 3 than for a better rank 5, so a higher listing for rank 3 is one
-- that doesn't sell. `sales` is rank -> price (nil without a price). Returns
-- rank -> capped price, and rank -> the higher rank that set the cap, for the
-- ranks it lowered.
function Prices.CapRanks(sales, maxRank)
	local capped, cappedBy = {}, {}
	local lowest, lowestRank
	for rank = maxRank, 1, -1 do
		local price = sales[rank]
		if price then
			if lowest and lowest < price then
				capped[rank], cappedBy[rank] = lowest, lowestRank
			else
				capped[rank] = price
				lowest, lowestRank = price, rank
			end
		end
	end
	return capped, cappedBy
end

-- How many of an item were up for sale the last day Auctionator scanned it, and
-- how many days ago that was (0 is today); nil when it has no count. Falls back
-- to Craftonomics' scan when Auctionator isn't used or has no count.
function Prices.Listed(link)
	local own = ownScan()
	if Prices.Scanner() == "own" then return own and own.Listed(link) end
	local db = Auctionator and Auctionator.Database
	local utilities = db and Auctionator.Utilities
	if db and db.GetPriceHistory and utilities and Auctionator.Constants then
		local ok, count, age = pcall(function()
			local keys
			utilities.DBKeyFromLink(link, function(found) keys = found end)
			keys = keys or { utilities.BasicDBKeyFromLink(link) }
			local today = math.floor((time() - Auctionator.Constants.SCAN_DAY_0) / 86400)
			for _, key in ipairs(keys) do
				-- Newest day first.
				for _, day in ipairs(db:GetPriceHistory(key)) do
					if day.available then return day.available, today - tonumber(day.rawDay) end
				end
			end
		end)
		if ok and count then return count, age end
	end
	if own then return own.Listed(link) end
end

-- Standard auction house deposit share of an item's vendor sell price, by
-- duration index: Retail (12h/24h/48h) or WoW Forever (2h/8h/24h).
local DEPOSIT_RATES = ns.QUALITY_CRAFTING and { 0.15, 0.30, 0.60 } or { 0.05, 0.20, 0.60 }

-- What putting `qty` of an item on the auction house costs as a deposit, for the
-- game's duration number `duration`, in copper, or nil when the game won't say.
-- You get it back when the auction sells, and lose it when it runs out unsold.
function Prices.Deposit(itemID, duration, qty)
	if C_AuctionHouse and C_AuctionHouse.CalculateCommodityDeposit then
		local ok, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, duration, qty)
		if ok and type(deposit) == "number" and deposit > 0 then return deposit end
	end
	-- Non-commodities (gear, tools) have no commodity deposit: fall back to the
	-- game's vendor-sell formula (at least 1s per auction on Retail).
	local rate = DEPOSIT_RATES[duration]
	local vendorSell = rate and itemID and select(11, C_Item.GetItemInfo(itemID))
	if vendorSell and vendorSell > 0 then
		local each = math.floor(vendorSell * rate)
		if ns.QUALITY_CRAFTING and each < 100 then each = 100 end
		local deposit = each * (qty or 1)
		if deposit > 0 then return deposit end
	end
end

-- Expected deposit copper lost before an item sells at `saleRate`: the final
-- successful sale refunds its deposit, leaving `deposit * (1/saleRate - 1)`.
function Prices.ExpectedDeposit(deposit, saleRate)
	if not (deposit and deposit > 0 and saleRate and saleRate > 0) then return nil end
	if saleRate >= 1 then return 0 end
	return math.floor(deposit * (1 - saleRate) / saleRate + 0.5)
end

-- Whether TSM is loaded, or another character's save of its prices is used here.
function Prices.TSMInstalled()
	return (TSM_API ~= nil and TSM_API.GetCustomPriceValue ~= nil)
		or (ns.SavedPrices.InUse() and ns.SavedPrices.Age() ~= nil)
end

-- Whether TSM is used for metrics (follows Price addon choice).
function Prices.HasTSM()
	return wantsTSM() and Prices.TSMInstalled()
end

-- Whose scan of the auction house the prices here are as old as: "auctionator",
-- "own" (Craftonomics'), or nil with TSM's prices, which need none.
function Prices.Scanner()
	if tsmAvailable() or Prices.SavedAge() then return nil end
	local api, own = auctionatorAPI(), ownScan()
	-- With both, the one whose prices come first, once Craftonomics has scanned.
	if api and not (own and ownFirst() and own.HasPrices()) then return "auctionator" end
	if own then return "own" end
end

-- Whether Craftonomics' scan may start by itself: its prices are in use, TSM's
-- aren't (they need no scan), and scanning is Craftonomics' part, or its scan is
-- the only price addon picked.
function Prices.ScansItself()
	-- Freshest prices: the scan has to keep up, where scanning is Craftonomics' part
	-- (not Auctionator's) and a scan can price something: without TSM, or with TSM's
	-- lowest auction as a price type.
	if ns.db.provider == "fresh" then
		local tsm = TSM_API and TSM_API.GetCustomPriceValue
		return ns.UsesOwn("ahPrice") and not savedPrices()
			and (not tsm or ns.db.matSource == LOWEST or ns.db.saleSource == LOWEST)
	end
	if tsmAvailable() or Prices.SavedAge() or not ownScan() then return false end
	return ns.db.provider == "own" or ns.UsesOwn("ahPrice")
end

-- How many days ago the saved TSM prices used here were saved, and the name of
-- the character who saved them. Nil when prices don't come from a save.
function Prices.SavedAge()
	if not savedPrices() then return end
	local age, name = ns.SavedPrices.Age()
	return age, name
end

-- How many sell per day across the region, from TSM, or nil without TSM or a
-- number. TSM rounds to whole numbers, so it's asked for a thousand times the
-- number and divided back.
function Prices.SoldPerDay(link)
	if not Prices.HasTSM() then return end
	if not (TSM_API and TSM_API.GetCustomPriceValue) then return ns.SavedPrices.SoldPerDay(link) end
	local ok, itemString = pcall(TSM_API.ToItemString, link)
	if not (ok and itemString) then return end
	local value = tsmValue("dbregionsoldperday*1000", itemString)
	if value then return value / 1000 end
	return tsmValue("dbregionsoldperday", itemString)
end

-- Whether TSM's region sale rate takes the place of Sells/day and Listed (in the
-- Best crafts list and on the panel): on WoW Forever, and only with TSM loaded.
-- There TSM's sale rate pools every ruleset of the region (Normal, PvP...) into one
-- number. Elsewhere the sale rate shows beside them (see Prices.HasSaleRate).
function Prices.ShowsSaleRate()
	return not ns.QUALITY_CRAFTING and wantsTSM() and TSM_API ~= nil and TSM_API.GetCustomPriceValue ~= nil
end

-- Which source provides sale rate right now: "tsm", "personal", or nil.
function Prices.SaleRateSource()
	if wantsTSM() and TSM_API ~= nil and TSM_API.GetCustomPriceValue ~= nil then return "tsm" end
	if ns.db.provider ~= "tsm" and ns.Sales and ns.Sales.HasSaleRate and ns.Sales.HasSaleRate() then return "personal" end
end

-- Whether sale rate can be shown (from TSM, or from your own auction mail history).
function Prices.HasSaleRate()
	return Prices.SaleRateSource() ~= nil
end

local function itemNameFromLink(link, itemID)
	local id = itemID or (type(link) == "string" and tonumber(link:match("item:(%d+)")))
	local name = id and C_Item.GetItemNameByID(id)
	if name and name ~= "" then return name end
	if link and C_Item.GetItemInfo then
		local ok, infoName = pcall(C_Item.GetItemInfo, link)
		if ok and infoName and infoName ~= "" then return infoName end
	end
	if type(link) == "string" then
		local bracketed = link:match("%[(.-)%]")
		if bracketed then
			bracketed = bracketed:gsub("|A.-|a", ""):gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
			bracketed = strtrim(bracketed)
			if bracketed ~= "" then return bracketed end
		end
	end
end

-- The share of an item's auctions that sell (0..1), plus source ("tsm" | "personal")
-- and (for personal) sold and total finished auction counts.
function Prices.SaleRate(link, itemID)
	if wantsTSM() and TSM_API and TSM_API.GetCustomPriceValue then
		local ok, itemString = pcall(TSM_API.ToItemString, link)
		if not (ok and itemString) then return end
		local value = tsmValue("dbregionsalerate*1000", itemString)
		if value then return value / 1000, "tsm" end
		return
	end
	if ns.db.provider ~= "tsm" and ns.Sales and ns.Sales.SaleRate then
		local name = itemNameFromLink(link, itemID)
		if name then
			local rate, sold, total = ns.Sales.SaleRate(name)
			if rate then return rate, "personal", sold, total end
		end
	end
end

-- Windows and outlier rejection thresholds for in-game Market Value & Historical Price.
local MARKET_DAYS = 14
local HISTORICAL_DAYS = 60
local OUTLIER_LOW, OUTLIER_HIGH = 0.25, 2.5

local historyCache, historyCacheStamp

local function trimmedAverage(points, weighted)
	local n = #points
	if n == 0 then return end
	if n == 1 then return math.floor(points[1].price + 0.5) end
	local sorted = {}
	for i, point in ipairs(points) do sorted[i] = point.price end
	table.sort(sorted)
	local median = n % 2 == 1 and sorted[(n + 1) / 2] or (sorted[n / 2] + sorted[n / 2 + 1]) / 2
	local low, high = 0, math.huge
	if n >= 3 then
		low, high = median * OUTLIER_LOW, median * OUTLIER_HIGH
	end
	local sum, weightTotal = 0, 0
	for _, point in ipairs(points) do
		if point.price >= low and point.price <= high then
			local w = weighted and (MARKET_DAYS - point.age) or 1
			sum = sum + point.price * w
			weightTotal = weightTotal + w
		end
	end
	if weightTotal <= 0 then return math.max(math.floor(median + 0.5), 1) end
	return math.max(math.floor(sum / weightTotal + 0.5), 1)
end

-- Computes 14-day recency-weighted Market Value and 60-day Historical Price from day -> lowestPrice.
local function computeMarketAndHistorical(byDay, todayDay)
	if type(byDay) ~= "table" or not todayDay then return end
	local marketPoints, histPoints = {}, {}
	local minAge, maxAge
	for day, price in pairs(byDay) do
		if type(day) == "number" and type(price) == "number" and price > 0 then
			local age = todayDay - day
			if age >= 0 and age < HISTORICAL_DAYS then
				local point = { age = age, price = price }
				histPoints[#histPoints + 1] = point
				if not minAge or age < minAge then minAge = age end
				if not maxAge or age > maxAge then maxAge = age end
				if age < MARKET_DAYS then marketPoints[#marketPoints + 1] = point end
			end
		end
	end
	local hasHistorical = #histPoints >= 3 and (maxAge - minAge) >= 2
	local hasMarket = #marketPoints >= 2 or (#marketPoints >= 1 and hasHistorical)
	local market = hasMarket and trimmedAverage(marketPoints, true) or nil
	local historical = (market and hasHistorical) and trimmedAverage(histPoints, false) or nil
	return market, historical
end

local function hasAuctionatorHistory()
	return auctionatorAPI() ~= nil
		and Auctionator.Database ~= nil
		and Auctionator.Database.GetPriceHistory ~= nil
		and Auctionator.Utilities ~= nil
		and Auctionator.Constants ~= nil
		and Auctionator.Constants.SCAN_DAY_0 ~= nil
end

local function auctionatorHistory(link, itemID)
	if not hasAuctionatorHistory() then return end
	local db, utilities = Auctionator.Database, Auctionator.Utilities
	local target = link or (itemID and ("item:" .. itemID))
	if not target then return end
	local ok, byDay, todayDay = pcall(function()
		local keys
		utilities.DBKeyFromLink(target, function(found) keys = found end)
		keys = keys or { utilities.BasicDBKeyFromLink(target) }
		if #keys == 0 and itemID then keys = { tostring(itemID) } end
		local today = math.floor((time() - Auctionator.Constants.SCAN_DAY_0) / 86400)
		for _, key in ipairs(keys) do
			local entries = db:GetPriceHistory(key)
			if type(entries) == "table" and #entries > 0 then
				local map = {}
				for _, entry in ipairs(entries) do
					local day = tonumber(entry.rawDay)
					local price = tonumber(entry.minSeen)
					if day and price and price > 0 then
						local age = today - day
						if age >= 0 and age < HISTORICAL_DAYS then
							if not map[day] or price < map[day] then map[day] = price end
						end
					end
				end
				if next(map) then return map, today end
			end
		end
	end)
	if ok and byDay then return byDay, todayDay end
end

local function historyStats(link, itemID)
	if not (link or itemID) then return end
	local own = ownScan()
	local stamp = string.format("%d:%s:%s:%d:%s",
		math.floor(time() / 86400),
		tostring(ns.db.provider),
		tostring(ns.db.ahPrice),
		ns.PriceScan and ns.PriceScan.HistoryVersion() or 0,
		tostring(auctionatorScanned() or 0))
	if historyCacheStamp ~= stamp then
		historyCacheStamp = stamp
		historyCache = {}
	end
	local cacheKey = link or ("i:" .. tostring(itemID))
	local cached = historyCache[cacheKey]
	if cached then
		return cached.market or nil, cached.historical or nil, cached.source or nil
	end

	local function tryOwn()
		if not (own and own.History) then return end
		local byDay, todayDay = own.History(link, itemID)
		if byDay then
			local m, h = computeMarketAndHistorical(byDay, todayDay)
			if m then return m, h, "own" end
		end
	end
	local function tryAuct()
		local byDay, todayDay = auctionatorHistory(link, itemID)
		if byDay then
			local m, h = computeMarketAndHistorical(byDay, todayDay)
			if m then return m, h, "auctionator" end
		end
	end

	local market, historical, source
	if ownFirst() then
		market, historical, source = tryOwn()
		if not market then market, historical, source = tryAuct() end
	else
		market, historical, source = tryAuct()
		if not market then market, historical, source = tryOwn() end
	end
	historyCache[cacheKey] = {
		market = market or false,
		historical = historical or false,
		source = source or false,
	}
	return market, historical, source
end

local function currentLowest(link, itemID)
	local fresh, freshFrom = freshSale(link, itemID, LOWEST)
	if fresh then return fresh, freshFrom end
	local api, own = auctionatorAPI(), ownScan()
	local function ownLowest()
		if own and (own.SaleInLastScan(link, itemID) or own.SaleChecked(link, itemID)) then
			return own.Sale(link, itemID), "own"
		end
	end
	local function auctLowest()
		if not api then return end
		local value = auctionatorValue(api.GetAuctionPriceByItemLink, link)
			or (itemID and auctionatorValue(api.GetAuctionPriceByItemID, itemID))
		if not value then return end
		local scanAt = auctionatorScanned()
		if scanAt then
			local src = { at = scanAt, seconds = math.max(time() - scanAt, 0) }
			if api.GetAuctionAgeByItemLink then
				local ok, age = pcall(api.GetAuctionAgeByItemLink, ADDON_NAME, link)
				if ok and type(age) == "number" then
					if not auctionatorSaw(api.GetAuctionAgeByItemLink, link, src) then return end
				elseif itemID and api.GetAuctionAgeByItemID then
					local okID, ageID = pcall(api.GetAuctionAgeByItemID, ADDON_NAME, itemID)
					if okID and type(ageID) == "number" and not auctionatorSaw(api.GetAuctionAgeByItemID, itemID, src) then return end
				end
			elseif itemID and api.GetAuctionAgeByItemID then
				local okID, ageID = pcall(api.GetAuctionAgeByItemID, ADDON_NAME, itemID)
				if okID and type(ageID) == "number" and not auctionatorSaw(api.GetAuctionAgeByItemID, itemID, src) then return end
			end
		end
		return value, "auctionator"
	end
	if ownFirst() then
		local value, from = ownLowest()
		if value then return value, from end
		return auctLowest()
	end
	local value, from = auctLowest()
	if value then return value, from end
	return ownLowest()
end

-- Which source provides Market Value and Trend right now: "tsm", "auctionator", "own", or nil.
function Prices.TrendSource()
	if wantsTSM() and TSM_API ~= nil and TSM_API.GetCustomPriceValue ~= nil then return "tsm" end
	local hasAuct = hasAuctionatorHistory()
	local hasOwn = ownScan() ~= nil and ns.PriceScan ~= nil and ns.PriceScan.HasHistory()
	if hasOwn and (ownFirst() or not hasAuct) then return "own" end
	if hasAuct then return "auctionator" end
	if hasOwn then return "own" end
end

-- Whether trend / market value can be shown: with TSM, Auctionator history, or Craftonomics' scan history.
function Prices.HasTrend()
	return Prices.TrendSource() ~= nil
end

-- An item's 14-day Market Value, in copper, and its source ("tsm", "auctionator", or "own").
function Prices.MarketValue(link, itemID)
	if wantsTSM() and TSM_API and TSM_API.GetCustomPriceValue then
		local ok, itemString = pcall(TSM_API.ToItemString, link)
		local market = ok and itemString and tsmValue("dbmarket", itemString)
		if market then return market, "tsm" end
		if ns.db.provider == "tsm" then return end
	end
	local market, _, source = historyStats(link, itemID)
	if market then return market, source end
end

-- How far an item's market value on your realm is from its historical price,
-- in whole percent (-20 for 20% below it), plus its source ("tsm", "auctionator", or "own").
function Prices.Trend(link, itemID)
	local market, historical, source = Prices.MarketAndHistorical(link, itemID)
	if not historical then return end
	return math.floor((market - historical) * 100 / historical + 0.5), source
end

-- An item's market value on your realm and its historical price, in copper, plus its source.
function Prices.MarketAndHistorical(link, itemID)
	if wantsTSM() and TSM_API and TSM_API.GetCustomPriceValue then
		local ok, itemString = pcall(TSM_API.ToItemString, link)
		local market = ok and itemString and tsmValue("dbmarket", itemString)
		local historical = market and tsmValue("dbhistorical", itemString)
		if historical then return market, historical, "tsm" end
		if ns.db.provider == "tsm" then return end
	end
	local market, historical, source = historyStats(link, itemID)
	if market and historical then return market, historical, source end
end

-- How far an item's lowest auction on your realm is from its market value, in
-- whole percent (-18 for 18% below it), where the lowest auction came from
-- ("tsm", "own", or "auctionator"), and where the market value came from.
function Prices.LowestVsMarket(link, itemID)
	if wantsTSM() and TSM_API and TSM_API.GetCustomPriceValue then
		local ok, itemString = pcall(TSM_API.ToItemString, link)
		local market = ok and itemString and tsmValue("dbmarket", itemString)
		if market then
			local lowest, from = freshSale(link, itemID, LOWEST)
			if not lowest then lowest, from = tsmValue(LOWEST, itemString), "tsm" end
			if not lowest then return end
			return math.floor((lowest - market) * 100 / market + 0.5), from, "tsm"
		end
		if ns.db.provider == "tsm" then return end
	end
	local market, marketFrom = Prices.MarketValue(link, itemID)
	if not market then return end
	local lowest, lowestFrom = currentLowest(link, itemID)
	if not lowest then return end
	return math.floor((lowest - market) * 100 / market + 0.5), lowestFrom, marketFrom
end

-- How many days ago Auctionator last saw an item on the auction house (0 is
-- today), or false when it's over three weeks or never. nil when prices don't
-- come from Auctionator (TSM keeps its own data).
local function auctionAge(fnName, arg)
	if tsmAvailable() or Prices.SavedAge() then return end
	local api = auctionatorAPI()
	local fn = api and api[fnName]
	if not fn then return end
	local ok, age = pcall(fn, ADDON_NAME, arg)
	if not ok then return end
	return type(age) == "number" and age or false
end

-- How many days ago the auction house was last scanned, by Auctionator (its full
-- scan or its automatic one) or by Craftonomics (0 is within the last day), or
-- false when it never was. Nil when prices come from neither (TSM keeps its own
-- up to date, and saved TSM prices have their own age, see Prices.SavedAge).
-- Auctionator keeps those times in its own saved state, not its API, so a change
-- on its side just means no answer.
function Prices.ScanAge()
	local scanner = Prices.Scanner()
	if scanner == "own" then return ns.PriceScan.Age() end
	if scanner ~= "auctionator" then return end
	if type(Auctionator.SavedState) ~= "table" then return end
	local last = auctionatorScanned()
	if not last then return false end
	return math.floor((time() - last) / 86400)
end

-- "yesterday", "3 days ago" or "never" for a scan age (see Prices.ScanAge).
function Prices.ScanAgeText(age)
	if age == false then return "never" end
	return Prices.AgeText(age)
end

-- A material's price age (see auctionAge). Vendor prices don't age.
function Prices.MaterialAge(itemID)
	if Prices.BuysAtVendor(itemID) then return end
	-- Crafted (Craft myself, Cheapest way): its own price isn't used.
	if ns.Chains.Crafted(itemID) then return end
	if Prices.Scanner() == "own" then return ns.PriceScan.MaterialAge(itemID) end
	return auctionAge("GetAuctionAgeByItemID", itemID)
end

-- A crafted item's price age (see auctionAge).
function Prices.SaleAge(link)
	if Prices.Scanner() == "own" then return ns.PriceScan.SaleAge(link) end
	return auctionAge("GetAuctionAgeByItemLink", link)
end

-- "today", "yesterday", "3 days ago" or "over 3 weeks ago" for a price age, or nil.
function Prices.AgeText(age)
	if age == nil then return end
	if age == false then return "over 3 weeks ago" end
	if age == 0 then return "today" end
	return age == 1 and "yesterday" or string.format("%d days ago", age)
end

-- "just now", "12 min ago", "3 hours ago" or "2 days ago" for a number of seconds.
function Prices.AgoText(seconds)
	if seconds < 60 then return "just now" end
	if seconds < 3600 then return string.format("%d min ago", math.floor(seconds / 60)) end
	if seconds < 86400 then
		local hours = math.floor(seconds / 3600)
		return hours == 1 and "1 hour ago" or string.format("%d hours ago", hours)
	end
	local days = math.floor(seconds / 86400)
	return days == 1 and "1 day ago" or string.format("%d days ago", days)
end

-- Where prices currently come from, for the panel's footer. Saved TSM prices say
-- whose they are, and how old while that's recent (old ones say it in red after
-- this, see Reminder.FooterText).
function Prices.SourceLabel()
	-- Freshest prices: who prices first right now, and how old its prices are.
	local first = (freshFor(ns.db.matSource) or freshFor(ns.db.saleSource) or {})[1]
	if first then
		return string.format("Freshest: %s, %s%s", FRESH_NAMES[first.name], first.name == "tsm" and "downloaded " or "",
			Prices.AgoText(first.seconds))
	end
	if tsmAvailable() then
		return "TSM (" .. ns.TSMSourceText(ns.db.matSource) .. ")" .. (ns.SavedPrices.Saving() and ", saving for alts..." or "")
	end
	local age, name, source
	if savedPrices() then age, name, source = ns.SavedPrices.Age() end
	if age then
		local label = string.format("%s's TSM (%s)", name, ns.TSMSourceText(source))
		if age < ns.Reminder.OLD_DAYS then label = label .. ", saved " .. Prices.AgeText(age) end
		return label
	end
	if auctionatorAPI() then return "Auctionator" end
	if ownScan() then
		return ns.PriceScan.HasPrices() and "Craftonomics' scan" or "none yet - scan at the auction house"
	end
	if ns.db.provider == "tsm" then return "TSM is not loaded" end
	return "Auctionator is not loaded"
end
