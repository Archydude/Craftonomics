-- Craftonomics: prices other addons can ask for (Hoard Value uses them).
-- CraftonomicsAPI.GetAuctionPrice(link) gives what one of an item sells for on
-- the auction house, in copper, the way Craftonomics prices crafted items: by its
-- Price addon option, so from TSM, TSM prices saved for alts, Auctionator or its
-- own scan of the auction house.
local _, ns = ...

local API = { VERSION = 1 }
CraftonomicsAPI = API

-- The price in copper and where it came from ("tsm", "saved", "auctionator" or
-- "own"), or nil when nobody knows it, and before Craftonomics' settings have loaded.
function API.GetAuctionPrice(link)
	if not ns.db or type(link) ~= "string" then return end
	local ok, value, from = pcall(ns.Prices.SaleFrom, link, (C_Item.GetItemInfoInstant(link)))
	if ok and type(value) == "number" and value > 0 then return value, from end
end
