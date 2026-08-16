-- Create_Background.lua - Migrated to ALUI namespace structure
-- Handles background UI creation with new namespace while maintaining backward compatibility

-- Use ALUI namespace if available, with fallbacks for compatibility
local GUI = (ALUI and ALUI.GUI) or GUI or {}
local Config = (ALUI and ALUI.Config) or {}
local RM = ALUI and ALUI.ResourceManager

local function getRuntimeConfig()
    return (ALUI and ALUI.Config) or Config
end

local function asNumber(value, default)
    local n = tonumber(value)
    if n == nil then
        return default
    end
    return n
end

local THEME_PALETTES = {
    dark = {
        mode = "dark",
        background = "#353535",
        boxBackground = "black",
        consoleBackground = "black",
        text = "white",
        border = "white",
        neutralStatus = "rgba(0,0,0,100)",
    },
    light = {
        mode = "light",
        background = "#E9E9E9",
        boxBackground = "#F8F8F8",
        consoleBackground = "white",
        text = "black",
        border = "#444444",
        neutralStatus = "rgba(255,255,255,210)",
    }
}

local function normalizeAppearance(value)
    if type(value) == "boolean" then
        return value and "dark" or "light"
    end

    if type(value) ~= "string" then
        return nil
    end

    local v = value:lower()
    if v:find("dark", 1, true) then
        return "dark"
    end
    if v:find("light", 1, true) then
        return "light"
    end

    return nil
end

local function resolveThemeMode()
    -- Prefer config API if it exposes appearance information.
    if type(getConfig) == "function" then
        local keys = { "appearance", "theme", "themeMode", "colorScheme", "colorMode", "darkMode" }
        for _, key in ipairs(keys) do
            local ok, value = pcall(getConfig, key)
            if ok then
                local mode = normalizeAppearance(value)
                if mode then
                    return mode
                end
            end
        end
    end

    -- Fall back to common Mudlet globals if present.
    if type(mudlet) == "table" then
        local mode = normalizeAppearance(mudlet.appearance)
            or normalizeAppearance(mudlet.theme)
            or normalizeAppearance(mudlet.themeMode)
            or normalizeAppearance(mudlet.darkMode)
            or normalizeAppearance(mudlet.isDarkMode)
            or normalizeAppearance(mudlet.isDarkTheme)
        if mode then
            return mode
        end
    end

    return "dark"
end

local function getActiveThemePalette()
    local mode = resolveThemeMode()
    return THEME_PALETTES[mode] or THEME_PALETTES.dark
end

-- Get configuration values with fallbacks
local sideBorderPercent = 25
local topBorderPercent = 5
local containerConfig = {}

local runtimeConfig = getRuntimeConfig()
if runtimeConfig and runtimeConfig.get then
    sideBorderPercent = asNumber((runtimeConfig.get("ui.sideBorderPercent", 25)), 25)
    topBorderPercent = asNumber((runtimeConfig.get("ui.topBorderPercent", 5)), 5)
    containerConfig = runtimeConfig.get("ui.containers", {})
end

-- Set default container config values
containerConfig.leftWidth = containerConfig.leftWidth or (sideBorderPercent .. "%")
containerConfig.rightWidth = containerConfig.rightWidth or (sideBorderPercent .. "%")
containerConfig.centerWidth = containerConfig.centerWidth or "50%"
containerConfig.topHeight = containerConfig.topHeight or (topBorderPercent .. "%")
containerConfig.fullHeight = containerConfig.fullHeight or "100%"

local function ensureHorizontalLayoutState()
    GUI.Layout = GUI.Layout or {}
    local cfg = getRuntimeConfig()
    local defaultSideBorderPercent = sideBorderPercent
    local configEpoch = nil
    if cfg and cfg.get then
        defaultSideBorderPercent = asNumber((cfg.get("ui.sideBorderPercent", defaultSideBorderPercent)), defaultSideBorderPercent)
        configEpoch = tonumber((cfg.get("ui.layout.lastSavedEpoch", 0))) or 0
    end

    if cfg and cfg.get and GUI.Layout.horizontalConfigEpoch ~= configEpoch then
        GUI.Layout.leftBorderPercent = asNumber((cfg.get("ui.layout.leftBorderPercent", defaultSideBorderPercent)), defaultSideBorderPercent)
        GUI.Layout.rightBorderPercent = asNumber((cfg.get("ui.layout.rightBorderPercent", defaultSideBorderPercent)), defaultSideBorderPercent)
        GUI.Layout.minSidePercent = asNumber((cfg.get("ui.layout.minSidePercent", 10)), 10)
        GUI.Layout.minCenterPercent = asNumber((cfg.get("ui.layout.minCenterPercent", 20)), 20)
        GUI.Layout.horizontalConfigEpoch = configEpoch
    end

    GUI.Layout.leftBorderPercent = tonumber(GUI.Layout.leftBorderPercent) or defaultSideBorderPercent
    GUI.Layout.rightBorderPercent = tonumber(GUI.Layout.rightBorderPercent) or defaultSideBorderPercent
    GUI.Layout.minSidePercent = tonumber(GUI.Layout.minSidePercent) or 10
    GUI.Layout.minCenterPercent = tonumber(GUI.Layout.minCenterPercent) or 20
    if GUI.Layout.activeHorizontalDrag ~= nil and type(GUI.Layout.activeHorizontalDrag) ~= "table" then
        GUI.Layout.activeHorizontalDrag = nil
    end
    return GUI.Layout
end

local getTotalUIWidth

local function persistHorizontalLayout()
    local runtimeConfig = (ALUI and ALUI.Config) or Config
    if not runtimeConfig or type(runtimeConfig.set) ~= "function" then
        return
    end

    local layout = ensureHorizontalLayoutState()
    local cfg = getRuntimeConfig()
    local mainWindowPadding = 6
    if cfg and cfg.get then
        mainWindowPadding = asNumber((cfg.get("ui.mainWindowPadding", mainWindowPadding)), 6)
    end

    local windowWidth = tonumber(getTotalUIWidth())
    if windowWidth and windowWidth > 0 then
        if GUI.Left and type(GUI.Left.get_width) == "function" then
            local leftWidth = tonumber(GUI.Left:get_width())
            if leftWidth then
                layout.leftBorderPercent = ((leftWidth - mainWindowPadding) / windowWidth) * 100
            end
        end

        if GUI.Right and type(GUI.Right.get_width) == "function" then
            local rightWidth = tonumber(GUI.Right:get_width())
            if rightWidth then
                layout.rightBorderPercent = ((rightWidth - mainWindowPadding) / windowWidth) * 100
            end
        end
    end

    local currentLayout = runtimeConfig.current and runtimeConfig.current.ui and runtimeConfig.current.ui.layout
    if type(currentLayout) == "table" then
        currentLayout.leftBorderPercent = tonumber(layout.leftBorderPercent) or sideBorderPercent
        currentLayout.rightBorderPercent = tonumber(layout.rightBorderPercent) or sideBorderPercent
        currentLayout.minSidePercent = tonumber(layout.minSidePercent) or 10
        currentLayout.minCenterPercent = tonumber(layout.minCenterPercent) or 20
        currentLayout.lastSavedEpoch = os.time()
    else
        runtimeConfig.set("ui.layout.leftBorderPercent", tonumber(layout.leftBorderPercent) or sideBorderPercent)
        runtimeConfig.set("ui.layout.rightBorderPercent", tonumber(layout.rightBorderPercent) or sideBorderPercent)
        runtimeConfig.set("ui.layout.minSidePercent", tonumber(layout.minSidePercent) or 10)
        runtimeConfig.set("ui.layout.minCenterPercent", tonumber(layout.minCenterPercent) or 20)
        if runtimeConfig.current and runtimeConfig.current.ui and runtimeConfig.current.ui.layout then
            runtimeConfig.current.ui.layout.lastSavedEpoch = os.time()
        end
    end
    if runtimeConfig.save then
        local ok, err = runtimeConfig.save()
        if not ok and type(cecho) == "function" then
            cecho(("<red>ALUI layout save failed: %s\n"):format(tostring(err)))
        end
    end
end

local horizontalPersistTimer = nil

local function scheduleHorizontalPersist()
    if horizontalPersistTimer then
        pcall(function() killTimer(horizontalPersistTimer) end)
        horizontalPersistTimer = nil
    end

    horizontalPersistTimer = tempTimer(0.35, function()
        horizontalPersistTimer = nil
        persistHorizontalLayout()
    end)
end

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

getTotalUIWidth = function()
    local width = getMainWindowSize()
    return width
end

local horizontalHandleStyles = {
    idle = [[
      background-color: qlineargradient(
        x1:0, y1:0, x2:1, y2:0,
        stop:0 rgba(0,0,0,0),
        stop:0.42 rgba(255,255,255,0.05),
        stop:0.50 rgba(255,255,255,0.35),
        stop:0.58 rgba(255,255,255,0.05),
        stop:1 rgba(0,0,0,0)
      );
    ]],
    hover = [[
      background-color: qlineargradient(
        x1:0, y1:0, x2:1, y2:0,
        stop:0 rgba(0,0,0,0),
        stop:0.38 rgba(255,255,255,0.10),
        stop:0.50 rgba(255,255,255,0.70),
        stop:0.62 rgba(255,255,255,0.10),
        stop:1 rgba(0,0,0,0)
      );
    ]],
    active = [[
      background-color: qlineargradient(
        x1:0, y1:0, x2:1, y2:0,
        stop:0 rgba(0,0,0,0),
        stop:0.35 rgba(117,209,255,0.15),
        stop:0.50 rgba(117,209,255,0.90),
        stop:0.65 rgba(117,209,255,0.15),
        stop:1 rgba(0,0,0,0)
      );
    ]],
}

local function setHorizontalHandleStyle(handle, styleName)
    if handle and horizontalHandleStyles[styleName] then
        handle:setStyleSheet(horizontalHandleStyles[styleName])
    end
end

local function setAllHorizontalHandlesIdle()
    if not GUI.HorizontalResizeHandles then
        return
    end

    for _, handle in pairs(GUI.HorizontalResizeHandles) do
        setHorizontalHandleStyle(handle, "idle")
    end
end

local function applyHorizontalResize()
    if GUI.setBackground then
        GUI.setBackground()
    end
    if GUI.setBorders then
        GUI.setBorders()
    end
    if GUI.resizeBoxes then
        GUI.resizeBoxes()
    end
end

local function beginHorizontalDrag(edge, handleName, event)
    local button = event and tostring(event.button or ""):lower() or ""
    if button ~= "" and not button:find("left") then
        return
    end

    local layout = ensureHorizontalLayoutState()
    layout.activeHorizontalDrag = {
        edge = edge,
        handleName = handleName,
        lastGlobalX = event and event.globalX or 0,
    }

    if GUI.HorizontalResizeHandlesByName then
        setHorizontalHandleStyle(GUI.HorizontalResizeHandlesByName[handleName], "active")
    end
end

local function dragHorizontal(edge, event)
    local layout = ensureHorizontalLayoutState()
    local drag = layout.activeHorizontalDrag
    if not drag or drag.edge ~= edge or not event or type(event.globalX) ~= "number" then
        return
    end

    local windowWidth = tonumber(getTotalUIWidth())
    if not windowWidth or windowWidth <= 0 then
        return
    end

    local mainWindowPadding = 6
    local cfg = getRuntimeConfig()
    if cfg and cfg.get then
        mainWindowPadding = asNumber((cfg.get("ui.mainWindowPadding", mainWindowPadding)), 6)
    end

    local minSidePercent = tonumber(layout.minSidePercent) or 10
    local minCenterPercent = tonumber(layout.minCenterPercent) or 20
    local minSidePx = math.max(80, math.floor(windowWidth * (minSidePercent / 100)))
    local minCenterPx = math.max(220, math.floor(windowWidth * (minCenterPercent / 100)))

    local leftBorderPct = tonumber(layout.leftBorderPercent) or sideBorderPercent
    local rightBorderPct = tonumber(layout.rightBorderPercent) or sideBorderPercent
    -- Continue from the size actually on screen (which setBackground may have
    -- clamped) so the panel does not jump on the first drag pixel.
    local leftBorderPx = tonumber(layout.leftBorderPx) or ((windowWidth * (leftBorderPct / 100)) + mainWindowPadding)
    local rightBorderPx = tonumber(layout.rightBorderPx) or ((windowWidth * (rightBorderPct / 100)) + mainWindowPadding)

    local delta = event.globalX - (drag.lastGlobalX or event.globalX)
    if delta == 0 then
        return
    end
    drag.lastGlobalX = event.globalX

    if edge == "left" then
        local maxLeftPx = math.max(minSidePx, windowWidth - rightBorderPx - minCenterPx)
        leftBorderPx = clamp(leftBorderPx + delta, minSidePx, maxLeftPx)
    else
        local maxRightPx = math.max(minSidePx, windowWidth - leftBorderPx - minCenterPx)
        rightBorderPx = clamp(rightBorderPx - delta, minSidePx, maxRightPx)
    end

    layout.leftBorderPx = leftBorderPx
    layout.rightBorderPx = rightBorderPx
    layout.leftBorderPercent = ((leftBorderPx - mainWindowPadding) / windowWidth) * 100
    layout.rightBorderPercent = ((rightBorderPx - mainWindowPadding) / windowWidth) * 100

    applyHorizontalResize()
    scheduleHorizontalPersist()
end

local function endHorizontalDrag()
    local layout = ensureHorizontalLayoutState()
    layout.activeHorizontalDrag = nil
    if horizontalPersistTimer then
        pcall(function() killTimer(horizontalPersistTimer) end)
        horizontalPersistTimer = nil
    end
    persistHorizontalLayout()
    setAllHorizontalHandlesIdle()
end

local function setHorizontalHandleHover(handleName, isHover)
    if not GUI.HorizontalResizeHandlesByName then
        return
    end

    local layout = ensureHorizontalLayoutState()
    if layout.activeHorizontalDrag then
        return
    end

    local handle = GUI.HorizontalResizeHandlesByName[handleName]
    if not handle then
        return
    end

    setHorizontalHandleStyle(handle, isHover and "hover" or "idle")
end

GUI.BackgroundCSS = CSSMan.new([[
  background-color: #353535;
]])

-- Register background CSS with ResourceManager
if RM then
    RM.registerCSS("backgroundCSS", GUI.BackgroundCSS, "background")
end

GUI.Left = Geyser.Label:new({
    name = "GUI.Left",
    x = 0,
    y = 0,
    width = containerConfig.leftWidth,
    height = containerConfig.fullHeight,
})
GUI.Left:setStyleSheet(GUI.BackgroundCSS:getCSS())

-- Register left background with ResourceManager
if RM then
    RM.registerUIElement("backgroundLeft", GUI.Left, "background")
end

GUI.Right = Geyser.Label:new({
    name = "GUI.Right",
    x = "-" .. containerConfig.rightWidth,
    y = 0,
    width = containerConfig.rightWidth,
    height = containerConfig.fullHeight,
    backgroundImages = "url('/banner.webp')",
})
GUI.Right:setStyleSheet(GUI.BackgroundCSS:getCSS())

-- Register right background with ResourceManager
if RM then
    RM.registerUIElement("backgroundRight", GUI.Right, "background")
end

GUI.Top = Geyser.Label:new({
    name = "GUI.Top",
    x = containerConfig.leftWidth,
    y = 0,
    width = containerConfig.centerWidth,
    height = containerConfig.topHeight,
})
GUI.Top:setStyleSheet(GUI.BackgroundCSS:getCSS())

-- Register top background with ResourceManager
if RM then
    RM.registerUIElement("backgroundTop", GUI.Top, "background")
end

local function createHorizontalHandle(name, parent, edge)
    local handle = Geyser.Label:new({
        name = name,
        x = (edge == "left") and "-6px" or "0px",
        y = "37.5%",
        width = "12px",
        height = "25%",
    }, parent)

    setHorizontalHandleStyle(handle, "idle")
    pcall(function() handle:setCursor("SplitHCursor") end)
    pcall(function() handle:setToolTip("Click and drag to resize") end)
    handle:setClickCallback(beginHorizontalDrag, edge, name)
    handle:setMoveCallback(dragHorizontal, edge)
    handle:setReleaseCallback(endHorizontalDrag)
    handle:setOnEnter(setHorizontalHandleHover, name, true)
    handle:setOnLeave(setHorizontalHandleHover, name, false)

    if RM then
        RM.registerUIElement(name, handle, "background")
    end

    return handle
end

GUI.HorizontalResizeHandles = {
    Left = createHorizontalHandle("GUI.HorizontalResizeLeft", GUI.Left, "left"),
    Right = createHorizontalHandle("GUI.HorizontalResizeRight", GUI.Right, "right"),
}
GUI.HorizontalResizeHandlesByName = {
    ["GUI.HorizontalResizeLeft"] = GUI.HorizontalResizeHandles.Left,
    ["GUI.HorizontalResizeRight"] = GUI.HorizontalResizeHandles.Right,
}

local function refreshThemeDrivenUI()
    if GUI.setBackground then GUI.setBackground() end
    if GUI.applyTheme then GUI.applyTheme() end
    if GUI.resizeBoxes then GUI.resizeBoxes() end
end

if type(registerNamedEventHandler) == "function" and type(getProfileName) == "function" then
    local profile = getProfileName()
    GUI.Events = GUI.Events or {}

    if GUI.Events.themeStyleSheetChanged then
        stopNamedEventHandler(profile, "ALUI.events.themeStyleSheetChanged")
        GUI.Events.themeStyleSheetChanged = nil
    end
    GUI.Events.themeStyleSheetChanged = registerNamedEventHandler(
        profile,
        "ALUI.events.themeStyleSheetChanged",
        "sysAppStyleSheetChange",
        function(_, _, source)
            if source == "system" then
                refreshThemeDrivenUI()
            end
        end,
        false
    )

    if GUI.Events.themeSettingChanged then
        stopNamedEventHandler(profile, "ALUI.events.themeSettingChanged")
        GUI.Events.themeSettingChanged = nil
    end
    GUI.Events.themeSettingChanged = registerNamedEventHandler(
        profile,
        "ALUI.events.themeSettingChanged",
        "sysSettingChanged",
        function(_, settingName)
            if type(settingName) ~= "string" then
                return
            end
            local lowerSettingName = settingName:lower()
            if lowerSettingName:find("theme", 1, true)
                or lowerSettingName:find("appearance", 1, true)
                or lowerSettingName:find("style", 1, true) then
                refreshThemeDrivenUI()
            end
        end,
        false
    )
end

-- Core background setup function
local function setBackground()
    local mainWindowPadding = 6

    local cfg = getRuntimeConfig()
    if cfg and cfg.get then
        topBorderPercent = asNumber((cfg.get("ui.topBorderPercent", topBorderPercent)), topBorderPercent)
        mainWindowPadding = asNumber((cfg.get("ui.mainWindowPadding", mainWindowPadding)), 6)
    end

    local layout = ensureHorizontalLayoutState()

    local _, height = getMainWindowSize()
    local width = tonumber(getTotalUIWidth())
    if type(width) ~= "number" or width <= 0 then return end
    local minSidePercent = tonumber(layout.minSidePercent) or 10
    local minCenterPercent = tonumber(layout.minCenterPercent) or 20
    local minSidePx = math.max(80, math.floor(width * (minSidePercent / 100)))
    local minCenterPx = math.max(220, math.floor(width * (minCenterPercent / 100)))

    local leftBorderPct = tonumber(layout.leftBorderPercent) or sideBorderPercent
    local rightBorderPct = tonumber(layout.rightBorderPercent) or sideBorderPercent
    local leftBorderPx = (width * (leftBorderPct / 100)) + mainWindowPadding
    local rightBorderPx = (width * (rightBorderPct / 100)) + mainWindowPadding

    local maxLeftPx = math.max(minSidePx, width - rightBorderPx - minCenterPx)
    leftBorderPx = clamp(leftBorderPx, minSidePx, maxLeftPx)
    local maxRightPx = math.max(minSidePx, width - leftBorderPx - minCenterPx)
    rightBorderPx = clamp(rightBorderPx, minSidePx, maxRightPx)

    -- Only the pixel values are stored. Writing the clamped size back into
    -- leftBorderPercent/rightBorderPercent would make shrinking the window
    -- permanently shrink the panels: the clamped ratio becomes the new desired
    -- ratio, so growing the window back never restores the original layout.
    layout.leftBorderPx = leftBorderPx
    layout.rightBorderPx = rightBorderPx

    local topBorderPx = (height * (topBorderPercent / 100)) + mainWindowPadding
    layout.topBorderPx = topBorderPx
    layout.mainWindowPadding = mainWindowPadding
    local centerWidthPx = math.max(1, width - leftBorderPx - rightBorderPx)

    local palette = getActiveThemePalette()
    GUI.Theme = GUI.Theme or {}
    GUI.Theme.mode = palette.mode
    GUI.Theme.palette = palette

    if GUI.BackgroundCSS then
        GUI.BackgroundCSS:set("background-color", palette.background)
        local bgCSS = GUI.BackgroundCSS:getCSS()
        if GUI.Left then GUI.Left:setStyleSheet(bgCSS) end
        if GUI.Right then GUI.Right:setStyleSheet(bgCSS) end
        if GUI.Top then GUI.Top:setStyleSheet(bgCSS) end
    end

    GUI.Left:move(0, 0)
    GUI.Left:resize(leftBorderPx, height)

    GUI.Right:move(width - rightBorderPx, 0)
    GUI.Right:resize(rightBorderPx, height)

    GUI.Top:move(leftBorderPx, 0)
    GUI.Top:resize(centerWidthPx, topBorderPx)

    GUI.Left:show()
    GUI.Right:show()
    GUI.Top:show()
    if GUI.HorizontalResizeHandles then
        if GUI.HorizontalResizeHandles.Left then
            pcall(function() GUI.HorizontalResizeHandles.Left:raise() end)
            GUI.HorizontalResizeHandles.Left:show()
        end

        if GUI.HorizontalResizeHandles.Right then
            pcall(function() GUI.HorizontalResizeHandles.Right:raise() end)
            GUI.HorizontalResizeHandles.Right:show()
        end
    end
    -- GUI.Bottom:show()

    local fontWidth = calcFontSize("main")

    if type(fontWidth) ~= "number" or fontWidth <= 0 then
        local fontSize = getFontSize()
        fontWidth = calcFontSize(fontSize)
    end

    if type(fontWidth) == "number" and fontWidth > 0 then
        local mainContentWidth = centerWidthPx
        local lineWidthAdjusted = math.max(20, math.floor(mainContentWidth / fontWidth) - 2)
        setWindowWrap("main", lineWidthAdjusted)
    end
end

-- Register function in both old and new namespaces for compatibility
GUI.setBackground = setBackground

-- Register in new ALUI namespace if available
if ALUI and ALUI.GUI then
    ALUI.GUI.setBackground = setBackground
    ALUI.GUI.getThemePalette = getActiveThemePalette
    ALUI.GUI.Components = ALUI.GUI.Components or {}
    ALUI.GUI.Components.background = setBackground

    -- Store UI components in ALUI namespace
    ALUI.GUI.Components.Left = GUI.Left
    ALUI.GUI.Components.Right = GUI.Right
    ALUI.GUI.Components.Top = GUI.Top
    ALUI.GUI.Styles = ALUI.GUI.Styles or {}
    ALUI.GUI.Styles.BackgroundCSS = GUI.BackgroundCSS
end
