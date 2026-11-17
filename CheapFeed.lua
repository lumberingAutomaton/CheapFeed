-- CheapFeed: a feed button for hunters. One click (or its keybind) casts Feed
-- Pet on the food in your bags with the best cost per happiness, priced from
-- Auctionator when it has data.
--
-- Forever makes the pet's exact happiness a "secret value": addons can show it
-- but not compare it or do maths with it (doing so is an uncatchable error).
-- So the exact number is only ever handed to widgets for display, and the
-- choice of food uses the three happiness states from GetPetHappiness.

local ADDON = "CheapFeed"

-- Classic food-level rule: levels the food may be below the pet, and the
-- happiness one feeding (10 bites) gives in that band. Forever is looser than
-- Classic (a pet ate food further below than this), so food beyond the last
-- band counts as the last band; food is only treated as refused once the game
-- actually refuses it. The ratios are what matter for the choice.
-- Measured on Forever: food 16 levels below a level 21 pet gave 5 happiness.
-- The first three bands are still Classic's numbers, not yet checked.
local LEVEL_BANDS = {
	{ below = 5,  happiness = 350 },
	{ below = 10, happiness = 170 },
	{ below = 14, happiness = 80 },
	{ below = math.huge, happiness = 5 },
}

local HAPPY = 3
-- Backpack, the four bags, and the reagent bag where the client has one.
local BAGS = { 0, 1, 2, 3, 4 }
if Enum.BagIndex and Enum.BagIndex.ReagentBag then
	BAGS[#BAGS + 1] = Enum.BagIndex.ReagentBag
end

local isSecret = issecretvalue or function() return false end
local function readable(v) return v ~= nil and not isSecret(v) end

local db
local pick            -- the chosen candidate, or nil
local ranked = {}     -- usable foods, best first (for the tooltip)
local foods = {}      -- every food the pet's diet allows, for the list window
local UpdateList      -- defined with the list window
local pendingRefresh = false
local lastClick       -- { id, petLevel, time } of our last use, to learn refusals

-- Item and pet reads ---------------------------------------------------------

local function ItemInfo(id)
	local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local name, _, _, itemLevel, _, _, _, _, _, icon, sellPrice = GetInfo(id)
	return name, itemLevel, icon, sellPrice
end

local function PetLevel()
	local level = UnitLevel("pet")
	return readable(level) and level or nil
end

-- Forever has it as C_PetInfo.GetPetHappiness; Classic as a global.
local GetHappiness = (C_PetInfo and C_PetInfo.GetPetHappiness) or GetPetHappiness

local function PetState()
	if not GetHappiness then return nil end
	local state = GetHappiness()
	return readable(state) and state or nil
end

local function PetEats(id)
	if not (C_PetInfo and C_PetInfo.CanPetEatItem) then return false end
	local ok, eats = pcall(C_PetInfo.CanPetEatItem, id)
	return ok and readable(eats) and eats == true
end

local function HappinessFor(itemLevel, petLevel)
	if not petLevel or not itemLevel then
		return LEVEL_BANDS[1].happiness
	end
	local below = petLevel - itemLevel
	for _, band in ipairs(LEVEL_BANDS) do
		if below <= band.below then
			return band.happiness
		end
	end
	return LEVEL_BANDS[#LEVEL_BANDS].happiness
end

-- What the food is worth to you: what you could get for it instead.
local function ValueOf(id, bound, sellPrice)
	if not bound and Auctionator and Auctionator.API and Auctionator.API.v1 then
		local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, ADDON, id)
		if ok and type(price) == "number" then
			return price, "auction"
		end
	end
	if type(sellPrice) == "number" and sellPrice > 0 then
		return sellPrice, "vendor"
	end
	return 0, "free"
end

-- Choosing -------------------------------------------------------------------

-- Every food in your bags that your pet's diet allows, each with a status:
-- nil (usable), "ignored" (you ignored it) or "low" (too low-level for the pet).
local function AllFoods()
	local petLevel = PetLevel()
	local byId = {}
	for _, bag in ipairs(BAGS) do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local id = info and info.itemID
			if readable(id) then
				local c = byId[id]
				if c then
					c.count = c.count + (info.stackCount or 1)
				elseif PetEats(id) then
					local name, itemLevel, icon, sellPrice = ItemInfo(id)
					if name then
						local refusedAt = db.tooLow[id]
						local happiness = HappinessFor(itemLevel, petLevel)
						local status
						if db.ignored[id] then
							status = "ignored"
						elseif refusedAt and petLevel and petLevel >= refusedAt then
							status = "low"
						end
						local value, source = ValueOf(id, info.isBound, sellPrice)
						byId[id] = {
							id = id, name = name, icon = icon or info.iconFileID,
							count = info.stackCount or 1, happiness = happiness or 0,
							value = value, source = source, status = status, itemLevel = itemLevel,
							perHappiness = happiness and value / happiness or math.huge,
						}
					end
				end
			end
		end
	end
	local list = {}
	for _, c in pairs(byId) do list[#list + 1] = c end
	return list
end

local function Rank(list, happy)
	table.sort(list, function(a, b)
		-- Already happy: there's little room left, so most of any feeding is
		-- wasted; spend as little as possible. Otherwise: cost per happiness.
		local ka, kb = a.perHappiness, b.perHappiness
		if happy then ka, kb = a.value, b.value end
		if ka ~= kb then return ka < kb end
		if a.count ~= b.count then return a.count < b.count end -- finish small stacks
		return a.id < b.id
	end)
	return list
end

-- The button -----------------------------------------------------------------

local button = CreateFrame("Button", "CheapFeedButton", UIParent, "SecureActionButtonTemplate")
button:SetSize(40, 40)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
-- The client acts on key/mouse *down* by default (ActionButtonUseKeyDown), which
-- would ignore these up-clicks entirely. Act on release instead.
button:SetAttribute("useOnKeyDown", false)
button:SetMovable(true)
button:SetClampedToScreen(true)
button:RegisterForDrag("LeftButton")
button:Hide()

button.icon = button:CreateTexture(nil, "ARTWORK")
button.icon:SetAllPoints()
button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
button.count:SetPoint("BOTTOMRIGHT", -2, 2)

-- Exact happiness: the secret value goes straight into widgets, never into Lua maths.
button.bar = CreateFrame("StatusBar", nil, button)
button.bar:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
button.bar:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
button.bar:SetHeight(5)
button.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
button.bar:SetStatusBarColor(0.25, 0.8, 0.25)
button.bar.bg = button.bar:CreateTexture(nil, "BACKGROUND")
button.bar.bg:SetAllPoints()
button.bar.bg:SetColorTexture(0, 0, 0, 0.6)

button.value = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
button.value:SetPoint("TOPRIGHT", button.bar, "BOTTOM", -1, -2)
button.max = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
button.max:SetPoint("TOPLEFT", button.bar, "BOTTOM", 1, -2)

local function UpdateHappiness()
	local power = Enum.PowerType.Happiness
	local max = UnitPowerMax("pet", power)
	button.bar:SetMinMaxValues(0, readable(max) and max > 0 and max or 1)
	local current = UnitPower("pet", power)
	button.bar:SetValue(current)
	button.value:SetText(current)
	button.max:SetText(readable(max) and ("/ " .. max) or "")
end

local FEED_PET_SPELL = 6991
local FEED_PET_ICON = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(FEED_PET_SPELL))
	or "Interface\\Icons\\Ability_Hunter_BeastTraining"

-- The spell name in the client's language, for the /cast line.
local function FeedPetName()
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(FEED_PET_SPELL)
	if not name and GetSpellInfo then name = GetSpellInfo(FEED_PET_SPELL) end
	return name or "Feed Pet"
end

local function UpdateLook()
	if pick then
		button.icon:SetTexture(pick.icon)
		button.icon:SetDesaturated(false)
		button.icon:SetVertexColor(1, 1, 1)
		button.count:SetText(pick.count > 1 and pick.count or "")
	else
		-- Nothing to feed: the Feed Pet icon, greyed with a faint red tint.
		button.icon:SetTexture(FEED_PET_ICON)
		button.icon:SetDesaturated(true)
		button.icon:SetVertexColor(1, 0.6, 0.6)
		button.count:SetText("")
	end
end

local function Refresh()
	if InCombatLockdown() then
		pendingRefresh = true
		return
	end
	pendingRefresh = false
	local happy = PetState() == HAPPY
	foods = AllFoods()
	ranked = {}
	for _, c in ipairs(foods) do
		if not c.status then ranked[#ranked + 1] = c end
	end
	Rank(ranked, happy)
	pick = ranked[1]
	-- Usable foods in rank order, then ignored, then too low-level (for the list window).
	local order = { [false] = 0, ignored = 1, low = 2 }
	local rankOf = {}
	for i, c in ipairs(ranked) do rankOf[c] = i end
	table.sort(foods, function(a, b)
		local sa, sb = order[a.status or false], order[b.status or false]
		if sa ~= sb then return sa < sb end
		if rankOf[a] and rankOf[b] then return rankOf[a] < rankOf[b] end
		return a.name < b.name
	end)
	-- Left click (and the keybind) uses the pick; right and middle click are ours only.
	-- One click: cast Feed Pet, then pick the food with its targeting cursor.
	button:SetAttribute("type1", pick and "macro" or nil)
	button:SetAttribute("macrotext1", pick and ("/cast %s\n/use item:%d"):format(FeedPetName(), pick.id) or nil)
	-- Shift+left is for moving the button: never feed on it.
	button:SetAttribute("shift-type1", "macro")
	button:SetAttribute("shift-macrotext1", "/stopmacro")
	UpdateLook()
	if UpdateList then UpdateList() end
end

local function ShowIfPet()
	if InCombatLockdown() then
		pendingRefresh = true
		return
	end
	button:SetShown(UnitExists("pet") and not UnitIsDead("pet"))
end

local function SavePosition()
	local point, _, relPoint, x, y = button:GetPoint(1)
	db.point = { point, relPoint, x, y }
end

local function RestorePosition()
	button:ClearAllPoints()
	local p = db.point
	if p then
		button:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		button:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
	end
end

button:SetScript("OnDragStart", function(self)
	if IsShiftKeyDown() and not InCombatLockdown() then
		self:StartMoving()
	end
end)
button:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	SavePosition()
end)

button:SetScript("PostClick", function(self, mouse)
	if mouse == "RightButton" then
		if pick and not InCombatLockdown() then
			db.ignored[pick.id] = pick.name
			print(("|cff40ff40CheapFeed:|r ignoring %s. Middle-click the button to undo."):format(pick.name))
			Refresh()
		end
	elseif mouse == "MiddleButton" then
		if CheapFeedList:IsShown() then CheapFeedList:Hide() else CheapFeedList:Show() end
	elseif pick and not IsShiftKeyDown() then
		lastClick = { id = pick.id, petLevel = PetLevel(), time = GetTime() }
	end
end)

button:SetScript("OnEnter", function(self)
	GameTooltip_SetDefaultAnchor(GameTooltip, self) -- where the game puts all tooltips
	if #ranked == 0 then
		GameTooltip:AddLine("No food in your bags that your pet will eat.", 1, 0.3, 0.3, true)
	end
	for i, c in ipairs(ranked) do
		if i > 8 then break end
		local r, g, b = 1, 1, 1
		if i == 1 then r, g, b = 0.25, 1, 0.25 end
		GameTooltip:AddLine(("%d. %s x%d"):format(i, c.name, c.count), r, g, b)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Left-click: feed the top food", 0.6, 0.6, 0.6)
	GameTooltip:AddLine("Middle-click: food list", 0.6, 0.6, 0.6)
	GameTooltip:AddLine("Right-click: ignore the top food", 0.6, 0.6, 0.6)
	GameTooltip:AddLine("Shift-left-drag: move", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Food list window (middle-click) ------------------------------------------------

local ROWS = 14
local ROW_HEIGHT = 22

local list = CreateFrame("Frame", "CheapFeedList", UIParent, "BackdropTemplate")
list:SetSize(380, 56 + ROWS * ROW_HEIGHT)
list:SetFrameStrata("DIALOG")
list:SetBackdrop(BACKDROP_DIALOG_32_32)
list:EnableMouse(true)
list:SetMovable(true)
list:SetClampedToScreen(true)
list:RegisterForDrag("LeftButton")
list:SetScript("OnDragStart", list.StartMoving)
list:SetScript("OnDragStop", list.StopMovingOrSizing)
list:Hide()
tinsert(UISpecialFrames, "CheapFeedList") -- Escape closes it


local close = CreateFrame("Button", nil, list, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
list.empty:SetPoint("TOP", 0, -40)
list.empty:SetText("No food in your bags that your pet eats.")

list.more = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
list.more:SetPoint("BOTTOM", 0, 18)

local rows = {}
for i = 1, ROWS do
	local row = CreateFrame("Frame", nil, list)
	row:SetSize(340, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 20, -30 - (i - 1) * ROW_HEIGHT)

	row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	row.check:SetSize(22, 22)
	row.check:SetPoint("LEFT")
	row.check:SetScript("OnClick", function(self)
		local c = row.food
		if not c or InCombatLockdown() then
			self:SetChecked(not self:GetChecked())
			return
		end
		db.ignored[c.id] = (not self:GetChecked()) and c.name or nil
		Refresh()
	end)
	row.check:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText(self:GetChecked() and "Untick to ignore this food" or "Tick to use this food again")
		GameTooltip:Show()
	end)
	row.check:SetScript("OnLeave", function() GameTooltip:Hide() end)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetPoint("LEFT", row.check, "RIGHT", 2, 0)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.name:SetWidth(170)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.info:SetPoint("RIGHT")
	row.info:SetJustifyH("RIGHT")

	-- Hovering the name shows the item's own tooltip.
	row.hover = CreateFrame("Frame", nil, row)
	row.hover:SetPoint("TOPLEFT", row.icon)
	row.hover:SetPoint("BOTTOMRIGHT", row.name)
	row.hover:SetScript("OnEnter", function(self)
		if row.food then
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetItemByID(row.food.id)
			GameTooltip:Show()
		end
	end)
	row.hover:SetScript("OnLeave", function() GameTooltip:Hide() end)

	rows[i] = row
end

UpdateList = function()
	if not list:IsShown() then return end
	list.empty:SetShown(#foods == 0)
	for i, row in ipairs(rows) do
		local c = foods[i]
		row.food = c
		row:SetShown(c ~= nil)
		if c then
			row.icon:SetTexture(c.icon)
			row.check:SetChecked(c.status ~= "ignored")
			row.check:SetEnabled(c.status ~= "low")
			local label = c.count > 1 and ("%s x%d"):format(c.name, c.count) or c.name
			if c.itemLevel then label = label .. (" |cff999999(L%d)|r"):format(c.itemLevel) end
			local info
			if c.status == "low" then
				info = "|cff808080refused: too low-level|r"
			else
				info = ("+%d happiness"):format(c.happiness)
			end
			if c == pick then
				label = "|cff40ff40" .. label .. "|r"
			elseif c.status then
				label = "|cff808080" .. label .. "|r"
			end
			row.name:SetText(label)
			row.info:SetText(info)
		end
	end
	local extra = #foods - ROWS
	list.more:SetText(extra > 0 and ("+%d more not shown"):format(extra) or "")
	-- Fit the window to the foods shown, up to ROWS; room for the "+N more" line past that.
	local shown = math.max(1, math.min(#foods, ROWS))
	list:SetHeight(56 + shown * ROW_HEIGHT + (extra > 0 and 14 or 0))
end

list:SetScript("OnShow", function(self)
	if not self.placed then
		self:SetPoint("BOTTOMLEFT", button, "TOPRIGHT", 8, 8)
		self.placed = true
	end
	UpdateList()
end)

-- Learning from refusals -------------------------------------------------------

local LOW_LEVEL = SPELL_FAILED_FOOD_LOWLEVEL or "That food's level is not high enough for your pet."
local WRONG_FOOD = SPELL_FAILED_WRONG_PET_FOOD or "Your pet doesn't like that food."

local function OnError(message)
	if not lastClick or GetTime() - lastClick.time > 2 or type(message) ~= "string" then return end
	if message == LOW_LEVEL and lastClick.petLevel then
		db.tooLow[lastClick.id] = lastClick.petLevel
	elseif message == WRONG_FOOD then
		db.ignored[lastClick.id] = (ItemInfo(lastClick.id)) or true
	else
		return
	end
	lastClick = nil
	Refresh()
end

-- Events -----------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1, arg2)
	if event == "PLAYER_LOGIN" then
		if select(2, UnitClass("player")) ~= "HUNTER" then return end
		CheapFeedDB = CheapFeedDB or {}
		db = CheapFeedDB
		db.ignored = db.ignored or {}
		db.tooLow = db.tooLow or {}
		RestorePosition()
		for _, e in ipairs({ "BAG_UPDATE_DELAYED", "UNIT_PET", "UNIT_HAPPINESS", "UNIT_LEVEL",
			"UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "PLAYER_REGEN_ENABLED", "GET_ITEM_INFO_RECEIVED",
			"UI_ERROR_MESSAGE", "PLAYER_ENTERING_WORLD", "PET_UI_UPDATE" }) do
			self:RegisterEvent(e)
		end
		ShowIfPet()
		UpdateHappiness()
		Refresh()
	elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" then
		if arg1 == "pet" then UpdateHappiness() end
	elseif event == "UNIT_HAPPINESS" or event == "UNIT_LEVEL" then
		if arg1 == "pet" then
			UpdateHappiness()
			Refresh()
		end
	elseif event == "UI_ERROR_MESSAGE" then
		OnError(arg2)
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingRefresh then
			ShowIfPet()
			Refresh()
		end
	else -- bags, pet summoned/dismissed, item data arrived, zoning
		ShowIfPet()
		UpdateHappiness()
		Refresh()
	end
end)

-- Slash command / keybind label ----------------------------------------------------

BINDING_HEADER_CHEAPFEED = "CheapFeed"
_G["BINDING_NAME_CLICK CheapFeedButton:LeftButton"] = "Feed the cheapest food"

SLASH_CHEAPFEED1 = "/cheapfeed"
SlashCmdList.CHEAPFEED = function(msg)
	if not db then return end
	msg = strtrim(msg or ""):lower()
	local ids = {}
	for id in pairs(db.ignored) do ids[#ids + 1] = id end
	table.sort(ids)
	local function NameOf(id)
		local name = type(db.ignored[id]) == "string" and db.ignored[id] or ItemInfo(id)
		return name or ("item " .. id)
	end
	local arg = msg:match("^unignore%s+(.+)$")
	if msg == "ignored" then
		if #ids == 0 then
			print("|cff40ff40CheapFeed:|r no ignored foods.")
		end
		for i, id in ipairs(ids) do
			print(("|cff40ff40CheapFeed:|r %d. %s"):format(i, NameOf(id)))
		end
	elseif arg then
		local n = tonumber(arg)
		local found = n and ids[n]
		if not found then
			for _, id in ipairs(ids) do
				if NameOf(id):lower():find(arg, 1, true) then found = id break end
			end
		end
		if found then
			print(("|cff40ff40CheapFeed:|r no longer ignoring %s."):format(NameOf(found)))
			db.ignored[found] = nil
			Refresh()
		else
			print("|cff40ff40CheapFeed:|r no ignored food matches that. Try /cheapfeed ignored")
		end
	elseif msg == "reset" then
		wipe(db.ignored)
		wipe(db.tooLow)
		print("|cff40ff40CheapFeed:|r cleared ignored and too-low foods.")
		Refresh()
	elseif msg == "center" and not InCombatLockdown() then
		db.point = nil
		RestorePosition()
	else
		print("|cff40ff40CheapFeed:|r /cheapfeed ignored  - list ignored foods")
		print("|cff40ff40CheapFeed:|r /cheapfeed unignore <number or name>  - stop ignoring one")
		print("|cff40ff40CheapFeed:|r /cheapfeed reset  - forget ignored and too-low foods")
		print("|cff40ff40CheapFeed:|r /cheapfeed center - move the button back to the middle")
	end
end
