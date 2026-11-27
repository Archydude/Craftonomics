-- Craftonomics: what one craft makes, on each recipe's row of the profession
-- window's own recipe list. The number is the Best crafts list's (see
-- BestCrafts.RowOf): at the rank and with the materials the crafting strategy
-- picks, so only recipes you know have one.
local _, ns = ...

local RecipeProfit = {}
ns.RecipeProfit = RecipeProfit

local Color, Money = ns.Color, ns.Format.Money

local GAP = 6             -- between a recipe's name and its profit
local RIGHT_PAD = 4       -- the profit to the row's right edge
local LABEL_PAD = 10      -- what the game keeps free next to a recipe's name
local MIN_NAME_WIDTH = 60 -- a row whose name would get narrower than this shows no profit
local REFRESH_DELAY = 0.3 -- redraws are batched this long
local SCAN_DELAY = 0.3    -- a profession that just showed is scanned after this long
local GOLD = 10000        -- copper
local TOGGLE_WIDTH, TOGGLE_HEIGHT = 86, 20
local TOGGLE_X, TOGGLE_Y = 66, -1 -- top-left of the profession window title bar, right of the portrait

local scrollBox       -- the game's recipe list
local toggle          -- top-bar button toggling Profit vs Crafting cost on the recipe list
local texts = {}      -- recipe row (the game's frame) -> our text on it
local narrowed = {}   -- rows whose name we made room next to
local refreshQueued, scanQueued, pendingMissing = false, false, nil
local stale = false   -- the window was closed since the prices were asked for

local function enabled()
	return ns.db.listProfit
end

local METRIC_INFO = {
	profit = {
		button = "List: Profit",
		label = "Profit",
		tip = "Showing craft profit on each recipe row.",
	},
	cost = {
		button = "List: Cost",
		label = "Crafting cost",
		tip = "Showing material crafting cost per craft on each recipe row.",
	},
	skillup = {
		button = "List: Net skill-up",
		label = "Net skill-up cost",
		tip = "Showing average net gold cost per skill point (materials minus resale or vendor value, divided by skill-up chance). Grey recipes are left blank.",
	},
	rawSkillup = {
		button = "List: Raw skill-up",
		label = "Raw skill-up cost",
		tip = "Showing average raw material cost per skill point (materials divided by skill-up chance, ignoring resale value). Grey recipes are left blank.",
	},
}

local function availableMetrics()
	if ns.SKILLUPS then return { "profit", "cost", "skillup", "rawSkillup" } end
	return { "profit", "cost" }
end

local function metric()
	local saved = ns.db.listMetric
	if saved == "cost" then return "cost" end
	if ns.SKILLUPS and (saved == "skillup" or saved == "rawSkillup") then return saved end
	return "profit"
end

-- Whether the profits/costs can show now: your own profession's recipe list.
local function wanted()
	return enabled() and scrollBox ~= nil and scrollBox:IsVisible() and ns.Blizzard.IsOwnProfession()
end

local function formatAmount(amount)
	if ns.QUALITY_CRAFTING and math.abs(amount) >= GOLD then amount = math.floor(amount / GOLD + 0.5) * GOLD end
	return Money(amount)
end

-- The profit as a row shows it: in whole gold from 1 gold up where prices are
-- big, green or red. Grey with a "?" when a material has no price, since the
-- profit is too high then. Nil without a price for what the recipe makes.
local function profitText(row)
	local profit = ns.db.countProcs and row.expected or row.profit
	if not profit then return end
	local text = (profit > 0 and "+" or "") .. formatAmount(profit)
	if row.unpriced > 0 then return Color("muted", text .. "?") end
	return Color(ns.AmountColor(profit), text)
end

-- A material/skill-up cost formatted as a negative amount in light blue (or
-- muted with "?" when some materials lack prices). Blank when zero/free.
local function costAmountText(amount, unpriced)
	if not amount then return end
	if (unpriced or 0) > 0 then
		return Color("muted", amount > 0 and (formatAmount(-amount) .. "?") or "?")
	end
	if amount <= 0 then return end
	return Color("simulated", formatAmount(-amount))
end

-- What the materials for one craft cost, in light blue with a minus (or muted
-- with "?" when any material has no price). Shows for recipes without a sale price too.
local function costText(row)
	return costAmountText(row.cost, row.unpriced)
end

-- Average net gold cost per skill point on WoW Forever, in light blue ("Free"
-- when selling/vendoring covers the craft). Blank for grey recipes.
local function skillupText(row)
	local s = row.skillup
	if not (s and s.cost) then return end
	if (row.unpriced or 0) > 0 then
		if s.cost <= 0 then return Color("muted", "Free?") end
		return Color("muted", formatAmount(-s.cost) .. "?")
	end
	if s.cost <= 0 then return Color("simulated", "Free") end
	return Color("simulated", formatAmount(-s.cost))
end

-- Average raw material cost per skill point on WoW Forever (materials / chance),
-- ignoring resale value. Blank for grey recipes or free materials.
local function rawSkillupText(row)
	return costAmountText(row.skillup and row.skillup.rawCost, row.unpriced)
end

local function rowText(row)
	local m = metric()
	if m == "cost" then return costText(row) end
	if m == "skillup" then return skillupText(row) end
	if m == "rawSkillup" then return rawSkillupText(row) end
	return profitText(row)
end

-- Sets how wide a row's name is, as the game does when it fills the row in, with
-- `taken` more kept free on the right. False when that leaves the name too little.
local function fitName(frame, taken)
	local label, width = frame.Label, frame:GetWidth()
	local locked = frame.LockedIcon:IsShown() and frame.LockedIcon:GetWidth() or 0
	local count = frame.Count:IsShown() and frame.Count:GetStringWidth() or 0
	local room = width - (locked + count + LABEL_PAD + frame.SkillUps:GetWidth() + taken)
	if taken > 0 and room < MIN_NAME_WIDTH then return false end
	label:SetWidth(width)
	label:SetWidth(math.min(room, label:GetStringWidth()))
	return true
end

-- A row's recipe, as the game shows it there: the highest rank you know of a
-- recipe that has ranks. Nil for a row that isn't a recipe's.
local function recipeOf(frame)
	local node = frame.GetElementData and frame:GetElementData()
	local data = node and node.GetData and node:GetData()
	local info = data and data.recipeInfo
	if not info then return end
	local highest = Professions and Professions.GetHighestLearnedRecipe and Professions.GetHighestLearnedRecipe(info)
	return highest or info
end

local function scanSoon(recipeID)
	if recipeID and not pendingMissing then pendingMissing = recipeID end
	if scanQueued then return end
	scanQueued = true
	C_Timer.After(SCAN_DELAY, function()
		local missing = pendingMissing
		scanQueued, pendingMissing = false, nil
		if wanted() then ns.BestCrafts.Ensure(missing) end
	end)
end

local function textOn(frame)
	local text = texts[frame]
	if not text then
		-- The font of the row's name, where the game has it.
		text = frame:CreateFontString(nil, "OVERLAY",
			GameFontHighlight_NoShadow and "GameFontHighlight_NoShadow" or "GameFontHighlight")
		text:SetDrawLayer("OVERLAY", 1) -- with the row's name, under its highlight
		text:SetJustifyH("RIGHT")
		text:SetWordWrap(false)
		texts[frame] = text
	end
	return text
end

-- Takes a row's profit off, and gives its name the room back.
local function clearRow(frame)
	local text = texts[frame]
	if text then text:Hide() end
	if narrowed[frame] then
		narrowed[frame] = nil
		fitName(frame, 0)
	end
end

-- Draws one row of the recipe list: its profit at the right, the name cut short
-- before it.
local function drawRow(frame)
	-- Only recipe rows have these; categories and dividers don't.
	if not (type(frame) == "table" and frame.Label and frame.Count and frame.LockedIcon and frame.SkillUps) then return end
	local info = recipeOf(frame)
	if not (info and wanted()) then return clearRow(frame) end
	local row = ns.BestCrafts.RowOf(info.recipeID)
	if not row then
		scanSoon(info.recipeID)
		return clearRow(frame)
	end
	local shown = rowText(row)
	if not shown then return clearRow(frame) end
	local text = textOn(frame)
	text:SetText(shown)
	if not fitName(frame, text:GetStringWidth() + GAP) then return clearRow(frame) end
	narrowed[frame] = true
	local locked = frame.LockedIcon:IsShown() and frame.LockedIcon:GetWidth() or 0
	text:ClearAllPoints()
	text:SetPoint("RIGHT", frame, "RIGHT", -(RIGHT_PAD + locked), 0)
	text:Show()
end

local function nextMetric(current)
	local list = availableMetrics()
	for i, key in ipairs(list) do
		if key == current then return list[(i % #list) + 1] end
	end
	return list[1]
end

local function updateToggle()
	if not toggle then return end
	local info = METRIC_INFO[metric()]
	toggle:SetText(info.button)
	if toggle.SetWidth then
		local width = math.max(TOGGLE_WIDTH, (toggle.GetTextWidth and toggle:GetTextWidth() or 0) + 22)
		toggle:SetWidth(width)
	end
	toggle:SetShown(wanted())
end

local function showToggleTooltip(self)
	if not GameTooltip then return end
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	local current = metric()
	local info = METRIC_INFO[current]
	local nextInfo = METRIC_INFO[nextMetric(current)]
	local list = availableMetrics()
	GameTooltip:SetText("Recipe list: " .. info.label)
	local hint = info.tip .. "\n\nLeft-click: switch to " .. nextInfo.label .. "."
	if #list > 2 then hint = hint .. "\nRight-click: pick directly." end
	GameTooltip:AddLine(hint, 1, 1, 1, true)
	GameTooltip:Show()
end

-- The active recipe list metric key and metadata when the list overlay is on.
function RecipeProfit.ActiveMetric()
	if not enabled() then return end
	local m = metric()
	return m, METRIC_INFO[m]
end

function RecipeProfit.SetMetric(mode)
	local valid = false
	for _, key in ipairs(availableMetrics()) do
		if key == mode then valid = true; break end
	end
	if not valid then mode = "profit" end
	if ns.Options and ns.Options.Set then
		ns.Options.Set("listMetric", mode)
	else
		ns.db.listMetric = mode
		if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
	end
	updateToggle()
	RecipeProfit.Render()
	if toggle and GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(toggle) then
		showToggleTooltip(toggle)
	end
end

function RecipeProfit.ToggleMetric()
	RecipeProfit.SetMetric(nextMetric(metric()))
end

local function openToggleMenu(owner)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then return false end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		for _, key in ipairs(availableMetrics()) do
			local target = key
			root:CreateRadio(METRIC_INFO[target].label, function() return metric() == target end, function()
				RecipeProfit.SetMetric(target)
			end)
		end
	end)
	return true
end

function RecipeProfit.ToggleButton()
	return toggle
end

local function createToggle()
	if toggle or not (ProfessionsFrame and CreateFrame) then return end
	toggle = CreateFrame("Button", nil, ProfessionsFrame, "UIPanelButtonTemplate")
	toggle:SetSize(TOGGLE_WIDTH, TOGGLE_HEIGHT)
	toggle:SetPoint("TOPLEFT", ProfessionsFrame, "TOPLEFT", TOGGLE_X, TOGGLE_Y)
	local close = ProfessionsFrame.CloseButton
	if close and close.GetFrameLevel then toggle:SetFrameLevel(close:GetFrameLevel()) end
	if toggle.RegisterForClicks then toggle:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
	toggle:SetScript("OnClick", function(self, button)
		if button == "RightButton" and openToggleMenu(self) then return end
		RecipeProfit.ToggleMetric()
	end)
	toggle:SetScript("OnEnter", showToggleTooltip)
	toggle:SetScript("OnLeave", GameTooltip_Hide)
	updateToggle()
end

function RecipeProfit.Render()
	refreshQueued = false
	updateToggle()
	if not (scrollBox and scrollBox:IsVisible()) then return end
	-- A window opened again asks the price addons again.
	if stale and wanted() then
		stale = false
		ns.BestCrafts.Reprice(true)
	end
	if wanted() and ns.BestCrafts.IsStale and ns.BestCrafts.IsStale() then
		ns.BestCrafts.Ensure()
	end
	scrollBox:ForEachFrame(drawRow)
end

-- Redraws once shortly, however many times it's called.
function RecipeProfit.Refresh()
	updateToggle()
	if refreshQueued or not (scrollBox and scrollBox:IsVisible()) then return end
	refreshQueued = true
	C_Timer.After(REFRESH_DELAY, RecipeProfit.Render)
end

-- The game filled a row in. The row is the first frame among what it passes.
local function onRowFilled(...)
	for i = 1, select("#", ...) do
		local arg = select(i, ...)
		if type(arg) == "table" and arg.GetElementData and arg.GetObjectType then return drawRow(arg) end
	end
end

-- Follows the game's recipe list. Safe to call more than once.
function RecipeProfit.Init()
	if scrollBox or not ns.Blizzard.IsLoaded() then return end
	local event = ScrollBoxListMixin and ScrollBoxListMixin.Event and ScrollBoxListMixin.Event.OnInitializedFrame
	local list = ns.Blizzard.RecipeList()
	if not (event and list and list.ScrollBox and list.ScrollBox.RegisterCallback) then return end
	scrollBox = list.ScrollBox
	createToggle()
	scrollBox:RegisterCallback(event, onRowFilled, RecipeProfit)
	scrollBox:HookScript("OnShow", RecipeProfit.Refresh)
	scrollBox:HookScript("OnHide", updateToggle)
	ns.BestCrafts.Watch(RecipeProfit.Refresh, wanted)
	ns.Blizzard.WatchWindowClosed(function() stale = true end)

	-- What you own changes which materials a craft uses.
	local events = CreateFrame("Frame")
	events:RegisterEvent("BAG_UPDATE_DELAYED")
	events:SetScript("OnEvent", RecipeProfit.Refresh)
	RecipeProfit.Refresh()
end
