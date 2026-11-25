-- Craftonomics: notices when something you crafted leaves you some other way than
-- an auction or a craft, so the Ledger stops counting it as waiting to sell. Sold
-- to a vendor, used (thrown, drunk, eaten...), destroyed, or given away (mailed,
-- traded, put in the guild bank). It counts what you have of every item you've
-- crafted each time your bags change, and what's gone since the last count goes
-- by what you were doing then. What you put on the auction house or in your own
-- banks hasn't left.
--
-- A disenchant is a craft of its own: what it gave is read from the loot, and
-- the Ledger records it as crafted (see Ledger.RecordDisenchant), out of the
-- craft of yours that went with it, if one did.
local _, ns = ...

local Gone = {}
ns.Gone = Gone

local SETTLE = 0.5      -- seconds after your bags change before they're counted
local BAG_SETTLE = 0.5  -- seconds after a tracked bag leaves inventory to gather CHAT_MSG_LOOT lines
local BAG_TRACE_MAX = 14
local CRAFT_WINDOW = 2  -- seconds around a craft in which what goes is its materials
local AFTER = 3         -- seconds after a trade, a destroy or a disenchant in which what goes is its doing
local DISENCHANT = 13262 -- the Disenchant spell

local counts            -- itemID -> how many you had at the last count; nil until the first one
local queued = false    -- a count is on its way
local reason            -- what the items going would be down to, noted when the bags changed
local loading = true    -- a loading screen is up: what the game says you have can't be trusted
local bagLoading = false
local atMerchant, atMail, atAuction, atGuildBank, atBank = false, false, false, false, false
local craftedAt, tradedAt, destroyedAt = -math.huge, -math.huge, -math.huge
local disenchantedAt = -math.huge
-- What the last disenchant gave ({ { itemID, link, qty } ... }), until it's
-- recorded, and the disenchant that was read for.
local loot, lootReadFor
-- Dual-path tracking for patron & 600-Moxie containers:
-- Path 1 catches containers that open a loot window (even when Baganator/BetterBags
-- bypasses C_Container.UseContainerItem or GetLootSourceInfo returns empty).
-- Path 2 catches push-loot/instant bags (like Surplus Reagents or Payouts) that push items via
-- CHAT_MSG_LOOT without opening a loot window, deduplicating against Path 1 credits.
-- Path 3 falls back to positive inventory item deltas when a tracked bag opens silently
-- away from mail/bank/vendor/guildbank/trade/crafting/destroy.
local recordedBagGUIDs, pendingBag = {}, nil
local lootWindowRecorded = false
local path1OpenTimes, path1ChatQuota = {}, {}
local chatLootBuffer = {}
local trackedBagCounts, prevAllBagItems
local pendingPushDrops, pushQueued = {}, false
local selfLootLines
local bagTrace = {}

local function isSecret(v)
	return issecretvalue and issecretvalue(v)
end

local function crafting()
	return GetTime() - craftedAt <= CRAFT_WINDOW + SETTLE
		or (C_TradeSkillUI and C_TradeSkillUI.GetRemainingRecasts and C_TradeSkillUI.GetRemainingRecasts() > 0)
end

local function addBagTrace(msg)
	bagTrace[#bagTrace + 1] = string.format("[%.1fs] %s", GetTime and GetTime() or 0, msg)
	if #bagTrace > BAG_TRACE_MAX then
		table.remove(bagTrace, 1)
	end
end

local function notifyBagUI()
	if ns.Options and ns.Options.NotifyRewardsChanged then ns.Options.NotifyRewardsChanged() end
	if ns.Options and ns.Options.RefreshBagDrops then ns.Options.RefreshBagDrops() end
end

local function recordBagOpen(bagID, items, via, openCount, dropCounts)
	local opens = ns.Model.RecordBagOpen(bagID, items, openCount, dropCounts)
	if not opens then return false end
	local now = GetTime()
	if via == "loot-guid" or via == "loot-fallback" then
		local times = path1OpenTimes[bagID]
		if not times then
			times = {}
			path1OpenTimes[bagID] = times
		end
		local cut = now - 5
		local kept = {}
		for _, t in ipairs(times) do
			if t >= cut then kept[#kept + 1] = t end
		end
		kept[#kept + 1] = now
		path1OpenTimes[bagID] = kept

		for itemID, qty in pairs(items) do
			if type(itemID) == "number" and type(qty) == "number" and qty > 0 then
				local q = path1ChatQuota[itemID]
				if q and q.untilAt >= now then
					q.qty = q.qty + qty
					q.untilAt = now + 4
				else
					path1ChatQuota[itemID] = { qty = qty, untilAt = now + 4 }
				end
			end
		end
	end
	addBagTrace(string.format("recorded bag %d x%d via %s (total %d opens)", bagID, openCount or 1, via, opens))
	notifyBagUI()
	return true
end

local function maxPlayerBag()
	return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
end

local function scanPlayerBags()
	local tracked = {}
	if not (ns.Model and ns.Model.IsTrackedBag) then return tracked end
	if C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo then
		local allItems = {}
		for bag = 0, maxPlayerBag() do
			local numSlots = C_Container.GetContainerNumSlots(bag) or 0
			for slot = 1, numSlots do
				local info = C_Container.GetContainerItemInfo(bag, slot)
				local itemID = info and info.itemID
				if itemID and not isSecret(itemID) then
					local count = (info.stackCount and not isSecret(info.stackCount) and info.stackCount) or 1
					allItems[itemID] = (allItems[itemID] or 0) + count
					if ns.Model.IsTrackedBag(itemID) then
						tracked[itemID] = (tracked[itemID] or 0) + count
					end
				end
			end
		end
		return tracked, allItems
	end
	if C_Item and C_Item.GetItemCount then
		local checked = {}
		local function addID(id)
			if type(id) ~= "number" or checked[id] or not ns.Model.IsTrackedBag(id) then return end
			checked[id] = true
			local count = C_Item.GetItemCount(id, false, false, false)
			if count and not isSecret(count) and count > 0 then
				tracked[id] = count
			end
		end
		for id in pairs(ns.PATRON_BAGS or {}) do addID(id) end
		for id in pairs(ns.db and ns.db.bagDrops or {}) do addID(id) end
		for id in pairs(ns.db and ns.db.seenPatronBags or {}) do addID(id) end
	end
	return tracked, nil
end

local function findLockedTrackedBag()
	if not (ns.Model and ns.Model.IsTrackedBag and C_Container and C_Container.GetContainerNumSlots
		and C_Container.GetContainerItemInfo) then
		return nil
	end
	for bag = 0, maxPlayerBag() do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if info and info.isLocked and itemID and not isSecret(itemID) and ns.Model.IsTrackedBag(itemID) then
				return itemID, info.itemGUID
			end
		end
	end
end

local function noteBagInteraction(bag, slot, source)
	if not (ns.QUALITY_CRAFTING and bag and slot and C_Container and C_Container.GetContainerItemInfo) then return end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not info then return end
	if source == "lock" and not info.isLocked then return end
	local itemID = info.itemID
	if not (itemID and not isSecret(itemID) and ns.Model.IsTrackedBag(itemID)) then return end
	local guid = info.itemGUID and not isSecret(info.itemGUID) and info.itemGUID or nil
	pendingBag = { bagID = itemID, guid = guid, at = GetTime() }
	if not bagLoading and (trackedBagCounts == nil or (trackedBagCounts[itemID] or 0) == 0) then
		trackedBagCounts, prevAllBagItems = scanPlayerBags()
		if (trackedBagCounts[itemID] or 0) == 0 then
			trackedBagCounts[itemID] = 1
		end
	end
	addBagTrace(string.format("%s bag %d (slot %s:%s)", source, itemID, tostring(bag), tostring(slot)))
end

local function ensureSelfLootLines()
	if selfLootLines and #selfLootLines > 0 then return end
	selfLootLines = {}
	local function add(names, multiple)
		for _, name in ipairs(names) do
			local text = _G[name]
			if type(text) == "string" and text ~= "" then
				local countFirst = false
				if multiple then
					local itemPos = text:find("%%%d*%%?%$?s") or math.huge
					local countPos = text:find("%%%d*%%?%$?d") or math.huge
					countFirst = countPos < itemPos
				end
				local pattern = text:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
					:gsub("%%%d*%%?%$?s", "(.+)")
				if multiple then
					pattern = pattern:gsub("%%%d*%%?%$?d", "(%%d+)")
				end
				selfLootLines[#selfLootLines + 1] = {
					pattern = "^" .. pattern .. "$",
					multiple = multiple,
					countFirst = countFirst,
				}
			end
		end
	end
	add({
		"LOOT_ITEM_SELF_MULTIPLE",
		"LOOT_ITEM_PUSHED_SELF_MULTIPLE",
		"LOOT_ITEM_BONUS_ROLL_SELF_MULTIPLE",
	}, true)
	add({
		"LOOT_ITEM_SELF",
		"LOOT_ITEM_PUSHED_SELF",
		"LOOT_ITEM_BONUS_ROLL_SELF",
	}, false)
end

local function parseChatLoot(text)
	text = strtrim and strtrim(text) or text
	ensureSelfLootLines()
	for _, entry in ipairs(selfLootLines) do
		local first, second = text:match(entry.pattern)
		if first then
			local itemText = entry.multiple and entry.countFirst and second or first
			local count = entry.multiple and tonumber(entry.countFirst and first or second) or nil
			local from, to = itemText:find("|c[^|]+|Hitem:.-|h.-|h|r")
			if not from then
				from, to = itemText:find("|Hitem:.-|h.-|h")
			end
			if from then
				local link = itemText:sub(from, to)
				if not count then
					count = tonumber(itemText:match("^%s*x(%d+)", to + 1)) or 1
				end
				local itemID = (C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(link))
					or tonumber(link:match("Hitem:(%d+)"))
				if itemID and not isSecret(itemID) and itemID > 0 then
					return itemID, math.max(count or 1, 1)
				end
			end
		end
	end
end

local function onChatLoot(text)
	if not ns.QUALITY_CRAFTING or type(text) ~= "string" or isSecret(text) then return end
	local itemID, qty = parseChatLoot(text)
	if not itemID then return end
	local now = GetTime()
	local quota = path1ChatQuota[itemID]
	if quota then
		if quota.untilAt >= now and quota.qty > 0 then
			local take = math.min(qty, quota.qty)
			quota.qty = quota.qty - take
			qty = qty - take
			if quota.qty <= 0 then path1ChatQuota[itemID] = nil end
			if qty <= 0 then return end
		else
			path1ChatQuota[itemID] = nil
		end
	end
	local cut = now - 6
	local kept = {}
	for _, entry in ipairs(chatLootBuffer) do
		if entry.at >= cut and not entry.consumed then
			kept[#kept + 1] = entry
		end
	end
	kept[#kept + 1] = { itemID = itemID, qty = qty, at = now }
	chatLootBuffer = kept
	addBagTrace(string.format("chat loot item %d x%d", itemID, qty))
end

-- Resolves the container itemID behind a loot source GUID.
local function resolveBagID(guid)
	if type(guid) ~= "string" or isSecret(guid) or not guid:match("^Item%-") then
		return nil
	end
	if C_Item.GetItemIDByGUID then
		local ok, id = pcall(C_Item.GetItemIDByGUID, guid)
		if ok and id and not isSecret(id) and id > 0 then return id end
	end
	if C_Item.GetItemLocation and C_Item.GetItemID then
		local ok, location = pcall(C_Item.GetItemLocation, guid)
		if ok and location and location:IsValid() and C_Item.DoesItemExist(location) then
			local id = C_Item.GetItemID(location)
			if id and not isSecret(id) and id > 0 then return id end
		end
	end
	if pendingBag and GetTime() - pendingBag.at <= 3
		and (not pendingBag.guid or pendingBag.guid == guid or ns.Model.IsTrackedBag(pendingBag.bagID)) then
		return pendingBag.bagID
	end
	local lockedID = findLockedTrackedBag()
	if lockedID then return lockedID end
end

-- Records opened patron and 600-Moxie bags via loot window when available.
local function readBagLoot(isFromItem)
	if not (ns.QUALITY_CRAFTING and GetNumLootItems) then return end
	local itemSlotType = Enum and Enum.LootSlotType and Enum.LootSlotType.Item or 1
	local byGUID, allLootItems = {}, {}
	local hasWorldSource, hasItemSource = false, false

	for slot = 1, GetNumLootItems() do
		local slotType = not GetLootSlotType or GetLootSlotType(slot)
		if slotType == true or slotType == itemSlotType then
			local link = GetLootSlotLink(slot)
			if link and not isSecret(link) then
				local itemID = C_Item.GetItemInfoInstant(link)
				if itemID and not isSecret(itemID) then
					local _, _, slotQty = GetLootSlotInfo(slot)
					local qtyFallback = (slotQty and not isSecret(slotQty) and tonumber(slotQty)) or 1
					allLootItems[itemID] = (allLootItems[itemID] or 0) + math.max(qtyFallback, 1)

					if GetLootSourceInfo then
						local sources = { GetLootSourceInfo(slot) }
						for i = 1, #sources, 2 do
							local guid, srcCount = sources[i], sources[i + 1]
							if type(guid) == "string" and not isSecret(guid) then
								if guid:match("^Creature%-") or guid:match("^GameObject%-") then
									hasWorldSource = true
								elseif guid:match("^Item%-") then
									hasItemSource = true
									if not recordedBagGUIDs[guid] then
										local bagID = resolveBagID(guid)
										if bagID and ns.Model.IsTrackedBag(bagID) then
											local qty = (srcCount and not isSecret(srcCount) and tonumber(srcCount))
												or qtyFallback
											local entry = byGUID[guid]
											if not entry then
												entry = { bagID = bagID, items = {} }
												byGUID[guid] = entry
											end
											entry.items[itemID] = (entry.items[itemID] or 0) + math.max(qty, 1)
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	local recorded = false
	for guid, entry in pairs(byGUID) do
		if next(entry.items) ~= nil then
			recordedBagGUIDs[guid] = true
			lootWindowRecorded = true
			pendingBag = nil
			recordBagOpen(entry.bagID, entry.items, "loot-guid")
			recorded = true
		end
	end

	if not recorded and not lootWindowRecorded and not hasWorldSource
		and GetTime() - disenchantedAt > AFTER and next(allLootItems) ~= nil then
		local recentPending = pendingBag and GetTime() - pendingBag.at <= 3 and pendingBag.bagID or nil
		local fallbackBagID = findLockedTrackedBag()
			or ((isFromItem or hasItemSource or recentPending) and recentPending or nil)
		if fallbackBagID and ns.Model.IsTrackedBag(fallbackBagID) then
			lootWindowRecorded = true
			pendingBag = nil
			recordBagOpen(fallbackBagID, allLootItems, "loot-fallback")
		end
	end
end

local function consumePath1Credit(bagID, maxCount)
	local times = path1OpenTimes[bagID]
	if not times or #times == 0 then return 0 end
	local cut = GetTime() - 5
	local kept, consumed = {}, 0
	for _, t in ipairs(times) do
		if t >= cut then
			if consumed < maxCount then
				consumed = consumed + 1
			else
				kept[#kept + 1] = t
			end
		end
	end
	path1OpenTimes[bagID] = #kept > 0 and kept or nil
	return consumed
end

local function flushPushDrops()
	pushQueued = false
	if bagLoading then
		pendingPushDrops = {}
		return
	end
	local active = {}
	for bagID, drop in pairs(pendingPushDrops) do
		local remaining = drop.opens - consumePath1Credit(bagID, drop.opens)
		if remaining > 0 then
			active[#active + 1] = {
				bagID = bagID,
				opens = remaining,
				firstAt = drop.firstAt,
				beforeItems = drop.beforeItems,
				allowDiff = drop.allowDiff,
			}
		end
	end
	pendingPushDrops = {}
	if #active == 0 then return end
	if #active > 1 then
		addBagTrace("skipped ambiguous multi-bag push (" .. #active .. " bag types)")
		return
	end

	local drop = active[1]
	local items, dropCounts, matched = {}, {}, {}
	local cutoff = drop.firstAt - 2.0
	for _, entry in ipairs(chatLootBuffer) do
		if not entry.consumed and entry.at >= cutoff and entry.itemID ~= drop.bagID then
			items[entry.itemID] = (items[entry.itemID] or 0) + entry.qty
			dropCounts[entry.itemID] = math.min((dropCounts[entry.itemID] or 0) + 1, drop.opens)
			matched[#matched + 1] = entry
		end
	end
	if next(items) ~= nil then
		for _, entry in ipairs(matched) do
			entry.consumed = true
		end
		recordBagOpen(drop.bagID, items, "chat-bag", drop.opens, dropCounts)
		return
	end

	local now = GetTime()
	local canDiff = drop.allowDiff and drop.beforeItems
		and not (atBank or atMail or atGuildBank or atMerchant or atAuction
			or crafting() or (now - tradedAt <= AFTER) or (now - destroyedAt <= AFTER))
	if canDiff then
		local _, curAll = scanPlayerBags()
		if curAll then
			local diffItems = {}
			for itemID, curQty in pairs(curAll) do
				if itemID ~= drop.bagID and not ns.Model.IsTrackedBag(itemID) then
					local prevQty = drop.beforeItems[itemID] or 0
					if curQty > prevQty then
						diffItems[itemID] = curQty - prevQty
					end
				end
			end
			if next(diffItems) ~= nil then
				recordBagOpen(drop.bagID, diffItems, "bag-diff", drop.opens)
				return
			end
		end
	end

	addBagTrace(string.format("bag %d left inventory with no loot items", drop.bagID))
end

local function checkTrackedBagDrops()
	if bagLoading or not ns.QUALITY_CRAFTING then return end
	local nowTracked, nowAll = scanPlayerBags()
	if trackedBagCounts == nil then
		trackedBagCounts, prevAllBagItems = nowTracked, nowAll
		return
	end
	local now = GetTime()
	local blocked = atBank or (now - destroyedAt <= AFTER)
	local allowDiffNow = not (atBank or atMail or atGuildBank or atMerchant or atAuction
		or crafting() or (now - tradedAt <= AFTER) or (now - destroyedAt <= AFTER))
	for bagID, oldCount in pairs(trackedBagCounts) do
		local newCount = nowTracked[bagID] or 0
		if newCount < oldCount then
			local delta = oldCount - newCount
			delta = delta - consumePath1Credit(bagID, delta)
			if delta > 0 then
				if blocked then
					addBagTrace(string.format("ignored bag %d -%d (bank/destroy)", bagID, delta))
				else
					local p = pendingPushDrops[bagID]
					if not p then
						pendingPushDrops[bagID] = {
							opens = delta,
							firstAt = now,
							lastAt = now,
							beforeItems = prevAllBagItems,
							allowDiff = allowDiffNow,
						}
					else
						p.opens = p.opens + delta
						p.lastAt = now
						p.allowDiff = p.allowDiff and allowDiffNow
					end
					addBagTrace(string.format("bag %d dropped %d -> %d (waiting loot chat)", bagID, oldCount, newCount))
					if not pushQueued then
						pushQueued = true
						C_Timer.After(BAG_SETTLE, flushPushDrops)
					end
				end
			end
		end
	end
	trackedBagCounts, prevAllBagItems = nowTracked, nowAll
end

-- Prints current tracked bags, saved bag drop totals and recent capture events.
function Gone.ExplainBags()
	local say = (ns.Shopping and ns.Shopping.Say) or print
	local current = scanPlayerBags()
	local curParts = {}
	for bagID, count in pairs(current) do
		curParts[#curParts + 1] = string.format("%s (%d) x%d", (ns.PATRON_BAGS and ns.PATRON_BAGS[bagID]) or tostring(bagID), bagID, count)
	end
	table.sort(curParts)
	say(#curParts > 0 and ("Tracked bags in inventory: " .. table.concat(curParts, ", "))
		or "Tracked bags in inventory: none.")

	local savedParts = {}
	for bagID, entry in pairs(ns.db and ns.db.bagDrops or {}) do
		if entry and entry.opens and entry.opens > 0 then
			savedParts[#savedParts + 1] = string.format("%d: %d open%s", bagID, entry.opens, entry.opens == 1 and "" or "s")
		end
	end
	table.sort(savedParts)
	say(#savedParts > 0 and ("Recorded bag totals: " .. table.concat(savedParts, ", "))
		or "Recorded bag totals: none yet.")

	if #bagTrace == 0 then
		say("Recent bag events: none since login/reload.")
	else
		say("Recent bag events (" .. #bagTrace .. "):")
		for _, line in ipairs(bagTrace) do
			say("  " .. line)
		end
	end
end

-- A craft just finished: the materials it took are recorded with it (see Ledger.RecordCraft).
function Gone.Crafted()
	craftedAt = GetTime()
end

-- What an item leaving right now is down to: "disenchanted", "vendor",
-- "destroyed", "given" or "used", or false when it hasn't left (on the auction
-- house) or a craft took it.
local function reasonNow()
	local now = GetTime()
	if now - disenchantedAt <= AFTER then return "disenchanted" end
	if atAuction or crafting() then return false end
	if atMerchant then return "vendor" end
	if now - destroyedAt <= AFTER then return "destroyed" end
	if atMail or atGuildBank or now - tradedAt <= AFTER then return "given" end
	return "used"
end

-- Reads what a disenchant gave from the loot window, once for each disenchant,
-- plus any tracked patron/Moxie bag opens.
local function readLoot(isFromItem)
	readBagLoot(isFromItem)
	if GetTime() - disenchantedAt > AFTER or lootReadFor == disenchantedAt then return end
	local found = {}
	for slot = 1, GetNumLootItems() do
		local link = GetLootSlotLink(slot)
		local itemID = link and C_Item.GetItemInfoInstant(link)
		if itemID then
			local _, _, qty = GetLootSlotInfo(slot)
			found[#found + 1] = { itemID = itemID, link = link, qty = math.max(qty or 1, 1) }
		end
	end
	if #found == 0 then return end
	lootReadFor, loot = disenchantedAt, found
end

-- Counts what you have of everything you've crafted. What's gone since the last
-- count is recorded, unless this is the first count or nothing says why.
local function count()
	queued = false
	local why = reason
	reason = nil
	if loading then return end
	local first = counts == nil
	counts = counts or {}
	-- The craft's result can arrive just after the bags changed.
	if crafting() and why ~= "disenchanted" then why = false end
	local disenchanted -- the craft of yours a disenchant took
	for itemID in pairs(ns.Ledger.CraftedItems()) do
		local now = ns.Model.Owned(itemID)
		local before = counts[itemID]
		if not first and why and before and now < before then
			local qty = before - now
			if why == "disenchanted" and not disenchanted then
				disenchanted = itemID
				qty = qty - 1
			end
			if qty > 0 then
				local how = why == "disenchanted" and "used" or why
				local pays = how == "vendor" and select(11, C_Item.GetItemInfo(itemID)) or 0
				ns.Ledger.RecordGone(itemID, qty, how, (pays or 0) * qty)
			end
		end
		counts[itemID] = now
	end
	-- After the count: what a disenchant gave becomes something you've crafted.
	if loot then
		local gave = loot
		loot = nil
		ns.Ledger.RecordDisenchant(disenchanted, gave)
	elseif disenchanted then
		-- What it gave wasn't seen: all that's known is that it's gone.
		ns.Ledger.RecordGone(disenchanted, 1, "used", 0)
	end
end

local function onBagsChanged()
	checkTrackedBagDrops()
	if loading then return end
	-- The first change of a batch says why: a window can close before the count.
	if reason == nil then reason = reasonNow() end
	if queued then return end
	queued = true
	C_Timer.After(SETTLE, count)
end

local HANDLERS = {
	BAG_UPDATE_DELAYED = onBagsChanged,
	MERCHANT_SHOW = function() atMerchant = true end,
	MERCHANT_CLOSED = function() atMerchant = false end,
	MAIL_SHOW = function() atMail = true end,
	MAIL_CLOSED = function() atMail = false end,
	AUCTION_HOUSE_SHOW = function() atAuction = true end,
	AUCTION_HOUSE_CLOSED = function() atAuction = false end,
	GUILDBANKFRAME_OPENED = function() atGuildBank = true end,
	GUILDBANKFRAME_CLOSED = function() atGuildBank = false end,
	BANKFRAME_OPENED = function() atBank = true end,
	BANKFRAME_CLOSED = function() atBank = false end,
	TRADE_CLOSED = function() tradedAt = GetTime() end,
	ITEM_LOCK_CHANGED = function(bag, slot) noteBagInteraction(bag, slot, "lock") end,
	CHAT_MSG_LOOT = onChatLoot,
	-- You disenchanted something: what goes now went that way, and the loot is what it gave.
	UNIT_SPELLCAST_SUCCEEDED = function(unit, _, spellID)
		if unit ~= "player" or spellID ~= DISENCHANT then return end
		disenchantedAt, loot = GetTime(), nil
	end,
	LOOT_READY = function() readLoot(false) end,
	LOOT_OPENED = function(_, isFromItem) readLoot(isFromItem == true) end,
	LOOT_CLOSED = function() lootWindowRecorded = false end,
	PLAYER_ENTERING_WORLD = function()
		if not bagLoading and ns.QUALITY_CRAFTING then
			trackedBagCounts, prevAllBagItems = scanPlayerBags()
		end
	end,
	LOADING_SCREEN_ENABLED = function()
		loading = true
		bagLoading = true
		trackedBagCounts, prevAllBagItems = nil, nil
		pendingPushDrops = {}
		pushQueued = false
	end,
	-- After a loading screen the count starts over: nothing is compared across it.
	LOADING_SCREEN_DISABLED = function()
		loading = false
		bagLoading = false
		counts, reason = nil, nil
		if ns.QUALITY_CRAFTING then
			trackedBagCounts, prevAllBagItems = scanPlayerBags()
		else
			trackedBagCounts, prevAllBagItems = nil, nil
		end
		onBagsChanged()
	end,
}

function Gone.Init()
	if ns.QUALITY_CRAFTING then ensureSelfLootLines() end
	local events = CreateFrame("Frame")
	for event in pairs(HANDLERS) do
		-- Not every version of the game has every one of these. Only your own spells matter.
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			events:RegisterUnitEvent(event, "player")
		else
			pcall(events.RegisterEvent, events, event)
		end
	end
	events:SetScript("OnEvent", function(_, event, ...) HANDLERS[event](...) end)
	hooksecurefunc("DeleteCursorItem", function() destroyedAt = GetTime() end)
	if ns.QUALITY_CRAFTING and C_Container and C_Container.UseContainerItem then
		hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
			noteBagInteraction(bag, slot, "use")
		end)
	end
end
