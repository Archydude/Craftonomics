-- Craftonomics: minimap button (LibDBIcon, so minimap button collectors pick it
-- up) and addon compartment entry. Click to open your profession window on the
-- Best crafts list, right-click for a menu (with Craftonomics' shopping list
-- when you use it), hover for this session's total.
local _, ns = ...

local Button = {}
ns.Minimap = Button

local format = string.format

local NAME = "Craftonomics" -- the button's name with LibDBIcon
local ICON = "Interface\\Icons\\INV_Hammer_20"
-- The menu's own lines each start with an icon, like its profession lines: a bag
-- for the shopping list, the Ledger's book (as on the Best crafts list), and a
-- recipe scroll for All recipes.
local SHOPPING_ICON = "Interface\\Icons\\INV_Misc_Bag_10"
local LEDGER_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local RECIPES_ICON = "Interface\\Icons\\INV_Scroll_06"
-- Degrees around the minimap where the button starts, away from where the other
-- addons in this folder start theirs (160, 200, 220).
local START_POSITION = 250

local LDBIcon = LibStub("LibDBIcon-1.0")
local registered = false

---------------------------------------------------------------------------
-- Your professions
---------------------------------------------------------------------------

-- Your crafting professions and cooking: { { name, icon, skillLine } ... }.
local function professions()
	local list = {}
	local first, second, _, _, cooking = GetProfessions()
	local slots = { first, second, cooking }
	for i = 1, 3 do
		local index = slots[i]
		if index then
			local name, icon, _, _, _, _, skillLine = GetProfessionInfo(index)
			if name and skillLine then list[#list + 1] = { name = name, icon = icon, skillLine = skillLine } end
		end
	end
	return list
end

-- The profession to open: the one whose window you opened last, or else your first.
local function lastProfession()
	local list = professions()
	local last = CraftonomicsCharDB and CraftonomicsCharDB.lastProfession
	for _, profession in ipairs(list) do
		if profession.skillLine == last then return profession end
	end
	return list[1]
end

-- Opens the standalone Best crafts window for `skillLine` without opening the
-- profession window.
local function openBestCrafts(skillLine)
	ns.BestCraftsList.Show(skillLine)
end

---------------------------------------------------------------------------
-- Clicks, menu and tooltip
---------------------------------------------------------------------------

-- Left-click: toggles the standalone Best crafts window for your last profession.
local function toggleBestCrafts()
	if ns.BestCraftsList.IsShown() then
		ns.BestCraftsList.Hide()
		return
	end
	local profession = lastProfession()
	if profession then
		openBestCrafts(profession.skillLine)
	elseif ns.Scans and ns.Scans.Entries and #ns.Scans.Entries() > 0 then
		ns.BestCraftsList.Show()
	else
		ns.Options.Open()
	end
end

-- A menu line's text with an icon before it.
local function withIcon(icon, text)
	return format("|T%s:16|t %s", icon, text)
end

local function openMenu()
	MenuUtil.CreateContextMenu(UIParent, function(_, root)
		root:CreateTitle("Craftonomics")
		for _, profession in ipairs(professions()) do
			root:CreateButton(withIcon(profession.icon, profession.name .. ": Best crafts"),
				function() openBestCrafts(profession.skillLine) end)
		end
		-- Craftonomics' own shopping list, when that's what you shop with or it has something on it.
		if ns.Shopping.ListTarget() == "own" or ns.Shopping.OwnHasItems() then
			root:CreateButton(withIcon(SHOPPING_ICON, "Shopping list"), function() ns.ShoppingList.Show("shop") end)
		end
		root:CreateButton(withIcon(LEDGER_ICON, "Ledger"), ns.LedgerWindow.Show)
		-- Every profession's recipes and how they sell.
		root:CreateButton(withIcon(RECIPES_ICON, "All recipes"), ns.AllRecipesWindow.Show)
		local strategies = root:CreateButton("Crafting strategy")
		for _, strategy in ipairs(ns.STRATEGIES) do
			local key = strategy[1]
			strategies:CreateRadio(strategy[2], function() return ns.db.craftStrategy == key end,
				function() ns.Options.Set("craftStrategy", key) end)
		end
		root:CreateDivider()
		root:CreateButton("Options", ns.Options.Open)
	end)
end

local function onClick(mouseButton)
	if mouseButton == "RightButton" then openMenu() else toggleBestCrafts() end
end

local function fillTooltip(tooltip)
	tooltip:SetText("Craftonomics")
	local session = ns.db.session
	if session.crafts > 0 then
		local luck = ns.Procs.LuckText()
		tooltip:AddDoubleLine(format("This session (%d craft%s)", session.crafts, session.crafts == 1 and "" or "s"),
			ns.Color(ns.AmountColor(session.total), ns.Format.Money(session.total)), 1, 1, 1)
		if luck then tooltip:AddLine(luck) end
	else
		tooltip:AddLine("Nothing crafted this session yet.", 1, 1, 1)
	end
	tooltip:AddLine(" ")
	local profession = lastProfession()
	tooltip:AddLine(profession and format("Click: %s's Best crafts", profession.name) or "Click: options", 0.6, 0.6, 0.6)
	tooltip:AddLine("Right-click: professions, shopping list, Ledger, crafting strategy, options", 0.6, 0.6, 0.6)
end

---------------------------------------------------------------------------
-- The button
---------------------------------------------------------------------------

-- Shows or hides the button, following the "Show minimap button" option.
function Button.Update()
	if not registered then return end
	if ns.db.minimap then LDBIcon:Show(NAME) else LDBIcon:Hide(NAME) end
end

function Button.Init()
	if registered then return end
	registered = true
	ns.db.minimapIcon = ns.db.minimapIcon or { minimapPos = START_POSITION }
	ns.db.minimapIcon.hide = not ns.db.minimap
	local launcher = LibStub("LibDataBroker-1.1"):NewDataObject(NAME, {
		type = "launcher",
		label = "Craftonomics",
		icon = ICON,
		OnClick = function(_, mouseButton) onClick(mouseButton) end,
		OnTooltipShow = fillTooltip,
	})
	LDBIcon:Register(NAME, launcher, ns.db.minimapIcon)
end

-- Remembers the profession whose window you opened last, for the next click.
local events = CreateFrame("Frame")
events:RegisterEvent("TRADE_SKILL_SHOW")
events:SetScript("OnEvent", function()
	if not ns.Blizzard.IsOwnProfession() then return end
	local skillLine = ns.Blizzard.ShownBaseProfession()
	if not skillLine then return end
	CraftonomicsCharDB = CraftonomicsCharDB or {}
	CraftonomicsCharDB.lastProfession = skillLine
end)

-- Addon compartment (the addon menu on Retail's minimap), named in the .toc.
function Craftonomics_OnAddonCompartmentClick(_, mouseButton)
	onClick(mouseButton)
end

function Craftonomics_OnAddonCompartmentEnter(_, menuButton)
	GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
	fillTooltip(GameTooltip)
	GameTooltip:Show()
end

function Craftonomics_OnAddonCompartmentLeave()
	GameTooltip:Hide()
end
