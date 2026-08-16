-- SwiftmendIndicator.lua
--
-- 12.1 rewrite. Aura data is secret in combat, so we no longer read auras at
-- all. Instead each unit frame gets an AuraContainer holding a single AuraSlot
-- filtered to our HoT spell IDs and to auras cast by the player. The container
-- shows the dot when a matching HoT is present; we control whether the
-- container itself is visible based on Swiftmend's cooldown (still readable,
-- via the non-secret isActive/isOnGCD fields).
--
-- Hard constraint learned by experiment: AuraContainers and AuraSlots can only
-- be CREATED out of combat -- doing so in combat fails silently, with no error.
-- SetPoint, SetUnit, Show and Hide all work fine in combat. So we pre-build a
-- pool out of combat and merely re-point pool entries as the roster changes.

SwiftmendIndicator = {}
local SI = SwiftmendIndicator

local SWIFTMEND_ID = 18562

-- Rejuvenation, Regrowth, Wild Growth, Germination.
-- All four are secret in combat as of 12.1; the container filters them for us.
local HOT_SPELL_IDS = { 774, 8936, 48438, 155777 }

local CONTAINER_TEMPLATE = "CustomAuraContainerTemplate"
local AURA_FILTER        = "HELPFUL|PLAYER"

-- Party (5) + raid (40) is the worst case we need to cover.
local POOL_SIZE = 45

-- Aura buttons are given a fixed generous size; the visible dot is a texture
-- inside them that we size ourselves. This lets appearance settings change
-- without rebuilding containers (which we cannot do in combat, and which would
-- leak frames since WoW frames can't be destroyed).
local BUTTON_SIZE = 32

local DEFAULTS = {
    shape       = "circle",
    size        = 8,
    anchorPoint = "TOPRIGHT",
    offsetX     = -2,
    offsetY     = -2,
    r           = 0,
    g           = 0.4,
    b           = 1,
    frameLevel  = 10,
}

local pool         = {}     -- array of entries: {container, slot, tex, mask, frame, unit, active}
local adapters     = {}
local poolBuilt    = false
local stylePending = false
SI.db = {}

-- ---------------------------------------------------------------------------
-- Debug
-- ---------------------------------------------------------------------------

local debugMode = false

function SI.Debug(...)
    if debugMode then print("|cff00ff00[SI]|r", ...) end
end

-- ---------------------------------------------------------------------------
-- Adapter registration
-- ---------------------------------------------------------------------------

-- Adapters must implement:
--   adapter.name              string
--   adapter:IsActive()        true when the target frame addon is usable
--   adapter:GetActiveFrames() returns an array of { frame = <Frame>, unit = <token> },
--                             visible frames only, deduplicated by frame object

function SI.RegisterAdapter(adapter)
    table.insert(adapters, adapter)
end

-- ---------------------------------------------------------------------------
-- Dot appearance
-- ---------------------------------------------------------------------------

local function StyleEntry(entry)
    local tex = entry.tex
    if not tex then return end   -- button not created yet; styled on creation

    local db = SI.db
    local ok, err = pcall(function()
        tex:SetSize(db.size, db.size)
        tex:SetColorTexture(db.r, db.g, db.b, 1)
        tex:SetRotation(db.shape == "diamond" and (math.pi / 4) or 0)

        if entry.mask then
            if db.shape == "circle" then
                tex:AddMaskTexture(entry.mask)
            else
                tex:RemoveMaskTexture(entry.mask)
            end
        end
    end)
    if not ok then SI.Debug("StyleEntry failed:", tostring(err)) end
end

function SI.ApplyStyleToAll()
    if InCombatLockdown() then
        -- Touching aura button children while auras are secret is unreliable;
        -- defer until we drop out of combat.
        stylePending = true
        SI.Debug("style change deferred until out of combat")
        return
    end
    stylePending = false
    for _, entry in ipairs(pool) do
        StyleEntry(entry)
    end
end

-- Builds the initializeFrame callback for a given pool entry. The container
-- calls this once, when it first creates the button for that slot.
local function MakeInitializeFrame(entry)
    return function(button)
        -- Never call SetIcon: without it the button draws nothing of its own,
        -- leaving just our texture. Also stop the button eating mouse input,
        -- so it can't interfere with click-casting on the frame beneath it.
        pcall(function()
            button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
            button:SetMouseMotionEnabled(false)
        end)

        local tex = button:CreateTexture(nil, "OVERLAY")
        tex:SetPoint("CENTER", button, "CENTER", 0, 0)
        entry.tex = tex

        local ok, mask = pcall(function()
            local m = button:CreateMaskTexture(nil, "BACKGROUND")
            m:SetAllPoints(tex)
            m:SetTexture(
                "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask",
                "CLAMPTOBLACKADDITIVE",
                "CLAMPTOBLACKADDITIVE"
            )
            return m
        end)
        if ok then entry.mask = mask end

        StyleEntry(entry)
    end
end

-- ---------------------------------------------------------------------------
-- Pool construction (out of combat only)
-- ---------------------------------------------------------------------------

local function CreateEntry()
    local entry = {}

    local c = CreateFrame("AuraContainer", nil, UIParent, CONTAINER_TEMPLATE)
    c:SetSize(1, 1)
    c:SetFrameStrata("MEDIUM")
    c:SetFrameLevel(SI.db.frameLevel)
    c:Hide()
    entry.container = c

    local ids = {}
    for _, id in ipairs(HOT_SPELL_IDS) do ids[id] = true end

    local ok, slot = pcall(function()
        return c:AddAuraSlot("dot", AURA_FILTER, {
            candidateFilters = { includeSpellIDs = ids },
            initializeFrame  = MakeInitializeFrame(entry),
        })
    end)

    if ok and type(slot) == "table" then
        entry.slot = slot
        -- Slots, unlike groups, are not auto-anchored.
        pcall(function()
            slot:SetSize(BUTTON_SIZE, BUTTON_SIZE)
            slot:ClearAllPoints()
            slot:SetPoint("CENTER", c, "CENTER", 0, 0)
        end)
    else
        SI.Debug("AddAuraSlot failed:", tostring(slot))
    end

    return entry
end

function SI.BuildPool()
    if poolBuilt then return true end
    if InCombatLockdown() then
        SI.Debug("cannot build pool in combat; will retry when combat ends")
        return false
    end

    for _ = 1, POOL_SIZE do
        table.insert(pool, CreateEntry())
    end
    poolBuilt = true
    SI.Debug("pool built:", #pool, "containers")
    return true
end

-- ---------------------------------------------------------------------------
-- Swiftmend cooldown
-- ---------------------------------------------------------------------------

function SI.SwiftmendIsReady()
    if not IsSpellKnown(SWIFTMEND_ID) then return false end
    local info = C_Spell.GetSpellCooldown(SWIFTMEND_ID)
    if not info then return false end
    -- isActive is true while on cooldown. isOnGCD lets us ignore the global,
    -- which would otherwise blink the dot off after every cast.
    return not info.isActive or info.isOnGCD
end

function SI.UpdateVisibility()
    local ready = SI.SwiftmendIsReady()
    for _, entry in ipairs(pool) do
        if entry.active and ready then
            entry.container:Show()
        else
            entry.container:Hide()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Assignment of pool entries to frames
-- ---------------------------------------------------------------------------

local function AssignFrames(list)
    local db = SI.db
    local used = {}

    for i, item in ipairs(list) do
        local entry = pool[i]
        if not entry then
            SI.Debug("pool exhausted at", i, "frames")
            break
        end
        used[entry] = true
        entry.active = true

        -- Re-anchor only when the frame actually changed.
        if entry.frame ~= item.frame or entry.dirtyAnchor then
            entry.container:ClearAllPoints()
            entry.container:SetPoint(db.anchorPoint, item.frame,
                                     db.anchorPoint, db.offsetX, db.offsetY)
            entry.container:SetFrameLevel(db.frameLevel)
            entry.frame = item.frame
            entry.dirtyAnchor = nil
        end

        -- Re-point the aura tracking only when the unit actually changed.
        if entry.unit ~= item.unit then
            entry.container:SetUnit(item.unit)
            entry.unit = item.unit
        end
    end

    for _, entry in ipairs(pool) do
        if not used[entry] then
            entry.active = false
            entry.frame  = nil
            entry.container:Hide()
        end
    end

    SI.UpdateVisibility()
end

function SI.Refresh()
    if not poolBuilt then
        if not SI.BuildPool() then return end
    end

    local list = {}
    for _, adapter in ipairs(adapters) do
        if adapter:IsActive() then
            for _, item in ipairs(adapter:GetActiveFrames()) do
                table.insert(list, item)
            end
        end
    end

    SI.Debug("refresh:", #list, "active frames")
    AssignFrames(list)
end

-- Forces every entry to re-anchor on the next refresh (used after the anchor
-- point or offsets change in settings).
function SI.MarkAnchorsDirty()
    for _, entry in ipairs(pool) do
        entry.dirtyAnchor = true
    end
    SI.Refresh()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "SwiftmendIndicator" then return end
        SwiftmendIndicatorDB = SwiftmendIndicatorDB or {}
        for k, v in pairs(DEFAULTS) do
            if SwiftmendIndicatorDB[k] == nil then
                SwiftmendIndicatorDB[k] = v
            end
        end
        SI.db = SwiftmendIndicatorDB
        SI.BuildSettingsPanel()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Frame addons need a moment to lay out their frames.
        C_Timer.After(1.0, SI.Refresh)

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- First safe opportunity to build the pool if we logged in mid-combat,
        -- and to apply any appearance changes made while fighting.
        if not poolBuilt then SI.Refresh() end
        if stylePending then SI.ApplyStyleToAll() end

    elseif event == "GROUP_ROSTER_UPDATE" then
        C_Timer.After(0.5, SI.Refresh)

    elseif event == "SPELL_UPDATE_COOLDOWN" then
        SI.UpdateVisibility()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        SI.UpdateVisibility()
        C_Timer.After(0.5, SI.Refresh)
    end
end)

SLASH_SWIFTMENDINDICATOR1 = "/si"
SlashCmdList["SWIFTMENDINDICATOR"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "debug" then
        debugMode = not debugMode
        print("|cff00ff00[SI]|r Debug mode:", debugMode and "ON" or "OFF")
    elseif msg == "refresh" then
        SI.Refresh()
        print("|cff00ff00[SI]|r refreshed")
    elseif msg == "status" then
        print("|cff00ff00[SI]|r pool built:", tostring(poolBuilt),
              "size:", #pool, "combat:", tostring(InCombatLockdown()))
        local n = 0
        for _, e in ipairs(pool) do if e.active then n = n + 1 end end
        print("|cff00ff00[SI]|r active containers:", n,
              "swiftmend ready:", tostring(SI.SwiftmendIsReady()))
    else
        print("|cff00ff00[SI]|r commands: debug | refresh | status")
    end
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local ANCHOR_POINTS = {
    "TOPLEFT", "TOP", "TOPRIGHT",
    "LEFT", "CENTER", "RIGHT",
    "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

function SI.BuildSettingsPanel()
    local db = SI.db
    local category = Settings.RegisterVerticalLayoutCategory("Swiftmend Indicator")

    Settings.CreateDropdown(category, Settings.RegisterProxySetting(
        category, "shape", Settings.VarType.String, "Shape", db.shape,
        function() return db.shape end,
        function(val) db.shape = val; SI.ApplyStyleToAll() end
    ), function()
        local c = Settings.CreateControlTextContainer()
        c:Add("circle",  "Circle")
        c:Add("diamond", "Diamond")
        c:Add("square",  "Square")
        return c:GetData()
    end, "Dot shape")

    local sizeOptions = Settings.CreateSliderOptions(4, 24, 1)
    sizeOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, Settings.RegisterProxySetting(
        category, "size", Settings.VarType.Number, "Size", db.size,
        function() return db.size end,
        function(val) db.size = val; SI.ApplyStyleToAll() end
    ), sizeOptions, "Dot size in pixels")

    Settings.CreateDropdown(category, Settings.RegisterProxySetting(
        category, "anchorPoint", Settings.VarType.String, "Anchor Point", db.anchorPoint,
        function() return db.anchorPoint end,
        function(val) db.anchorPoint = val; SI.MarkAnchorsDirty() end
    ), function()
        local c = Settings.CreateControlTextContainer()
        for _, pt in ipairs(ANCHOR_POINTS) do c:Add(pt, pt) end
        return c:GetData()
    end, "Position on the unit frame")

    local offsetOptions = Settings.CreateSliderOptions(-50, 50, 1)
    offsetOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)

    Settings.CreateSlider(category, Settings.RegisterProxySetting(
        category, "offsetX", Settings.VarType.Number, "X Offset", db.offsetX,
        function() return db.offsetX end,
        function(val) db.offsetX = val; SI.MarkAnchorsDirty() end
    ), offsetOptions, "Horizontal offset in pixels")

    Settings.CreateSlider(category, Settings.RegisterProxySetting(
        category, "offsetY", Settings.VarType.Number, "Y Offset", db.offsetY,
        function() return db.offsetY end,
        function(val) db.offsetY = val; SI.MarkAnchorsDirty() end
    ), offsetOptions, "Vertical offset in pixels")

    local colorOptions = Settings.CreateSliderOptions(0, 1, 0.01)
    colorOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)

    Settings.CreateSlider(category, Settings.RegisterProxySetting(
        category, "r", Settings.VarType.Number, "Dot Color: Red", db.r,
        function() return db.r end,
        function(val) db.r = val; SI.ApplyStyleToAll() end
    ), colorOptions, "Red (0-1)")

    Settings.CreateSlider(category, Settings.RegisterProxySetting(
        category, "g", Settings.VarType.Number, "Dot Color: Green", db.g,
        function() return db.g end,
        function(val) db.g = val; SI.ApplyStyleToAll() end
    ), colorOptions, "Green (0-1)")

    Settings.CreateSlider(category, Settings.RegisterProxySetting(
        category, "b", Settings.VarType.Number, "Dot Color: Blue", db.b,
        function() return db.b end,
        function(val) db.b = val; SI.ApplyStyleToAll() end
    ), colorOptions, "Blue (0-1)")

    local frameLevelOptions = Settings.CreateSliderOptions(1, 50, 1)
    frameLevelOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, Settings.RegisterProxySetting(
        category, "frameLevel", Settings.VarType.Number, "Frame Level", db.frameLevel,
        function() return db.frameLevel end,
        function(val) db.frameLevel = val; SI.MarkAnchorsDirty() end
    ), frameLevelOptions, "Draw order within MEDIUM strata (higher = in front)")

    Settings.RegisterAddOnCategory(category)
end
