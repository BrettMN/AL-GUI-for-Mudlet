-- Create_Background.lua - Migrated to ALUI namespace structure
-- Handles background UI creation with new namespace while maintaining backward compatibility

-- Use ALUI namespace if available, with fallbacks for compatibility
local GUI = (ALUI and ALUI.GUI) or GUI or {}
local Config = (ALUI and ALUI.Config) or {}
local RM = ALUI and ALUI.ResourceManager

-- Get configuration values with fallbacks
local sideBorderPercent = 25
local topBorderPercent = 5
local containerConfig = {}

if Config.get then
    sideBorderPercent = Config.get("ui.sideBorderPercent", 25)
    topBorderPercent = Config.get("ui.topBorderPercent", 5)
    containerConfig = Config.get("ui.containers", {})
end

-- Set default container config values
containerConfig.leftWidth = containerConfig.leftWidth or (sideBorderPercent .. "%")
containerConfig.rightWidth = containerConfig.rightWidth or (sideBorderPercent .. "%")
containerConfig.centerWidth = containerConfig.centerWidth or "50%"
containerConfig.topHeight = containerConfig.topHeight or (topBorderPercent .. "%")
containerConfig.fullHeight = containerConfig.fullHeight or "100%"

local function ensureHorizontalLayoutState()
    GUI.Layout = GUI.Layout or {}
    GUI.Layout.leftBorderPercent = tonumber(GUI.Layout.leftBorderPercent) or sideBorderPercent
    GUI.Layout.rightBorderPercent = tonumber(GUI.Layout.rightBorderPercent) or sideBorderPercent
    GUI.Layout.minSidePercent = tonumber(GUI.Layout.minSidePercent) or 10
    GUI.Layout.minCenterPercent = tonumber(GUI.Layout.minCenterPercent) or 20
    if GUI.Layout.activeHorizontalDrag ~= nil and type(GUI.Layout.activeHorizontalDrag) ~= "table" then
        GUI.Layout.activeHorizontalDrag = nil
    end
    return GUI.Layout
end

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function getTotalUIWidth()
    if GUI.Left and GUI.Top and GUI.Right
        and type(GUI.Left.get_width) == "function"
        and type(GUI.Top.get_width) == "function"
        and type(GUI.Right.get_width) == "function" then
        local leftW = GUI.Left:get_width()
        local topW = GUI.Top:get_width()
        local rightW = GUI.Right:get_width()

        if type(leftW) == "number" and type(topW) == "number" and type(rightW) == "number"
            and leftW > 0 and topW > 0 and rightW > 0 then
            return leftW + topW + rightW
        end
    end

    if GUI.Right and type(GUI.Right.get_x) == "function" and type(GUI.Right.get_width) == "function" then
        local rightX = GUI.Right:get_x()
        local rightW = GUI.Right:get_width()
        if type(rightX) == "number" and type(rightW) == "number" and rightW > 0 then
            return rightX + rightW
        end
    end

    return select(1, getMainWindowSize())
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

    local windowWidth = getTotalUIWidth()
    if not windowWidth or windowWidth <= 0 then
        return
    end

    local mainWindowPadding = 6
    if Config.get then
        mainWindowPadding = Config.get("ui.mainWindowPadding", mainWindowPadding)
    end

    local minSidePx = math.max(80, math.floor(windowWidth * (layout.minSidePercent / 100)))
    local minCenterPx = math.max(220, math.floor(windowWidth * (layout.minCenterPercent / 100)))

    local leftBorderPx = tonumber(layout.leftBorderPx) or ((windowWidth * (layout.leftBorderPercent / 100)) + mainWindowPadding)
    local rightBorderPx = tonumber(layout.rightBorderPx) or ((windowWidth * (layout.rightBorderPercent / 100)) + mainWindowPadding)

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

    applyHorizontalResize()
end

local function endHorizontalDrag()
    local layout = ensureHorizontalLayoutState()
    layout.activeHorizontalDrag = nil
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

-- Core background setup function
local function setBackground()
    local mainWindowPadding = 6

    if Config.get then
        topBorderPercent = Config.get("ui.topBorderPercent", topBorderPercent)
        mainWindowPadding = Config.get("ui.mainWindowPadding", mainWindowPadding)
    end

    local layout = ensureHorizontalLayoutState()

    local mainWidth, height = getMainWindowSize()
    local width = getTotalUIWidth()
    if type(width) ~= "number" or width <= 0 then
        width = mainWidth
    end
    local minSidePx = math.max(80, math.floor(width * (layout.minSidePercent / 100)))
    local minCenterPx = math.max(220, math.floor(width * (layout.minCenterPercent / 100)))

    local leftBorderPx = tonumber(layout.leftBorderPx)
    local rightBorderPx = tonumber(layout.rightBorderPx)

    if not leftBorderPx then
        leftBorderPx = (width * (layout.leftBorderPercent / 100)) + mainWindowPadding
    end

    if not rightBorderPx then
        rightBorderPx = (width * (layout.rightBorderPercent / 100)) + mainWindowPadding
    end

    local maxLeftPx = math.max(minSidePx, width - rightBorderPx - minCenterPx)
    leftBorderPx = clamp(leftBorderPx, minSidePx, maxLeftPx)
    local maxRightPx = math.max(minSidePx, width - leftBorderPx - minCenterPx)
    rightBorderPx = clamp(rightBorderPx, minSidePx, maxRightPx)

    layout.leftBorderPx = leftBorderPx
    layout.rightBorderPx = rightBorderPx
    layout.leftBorderPercent = ((leftBorderPx - mainWindowPadding) / width) * 100
    layout.rightBorderPercent = ((rightBorderPx - mainWindowPadding) / width) * 100

    local topBorderPx = (height * (topBorderPercent / 100)) + mainWindowPadding
    local centerWidthPx = math.max(1, width - leftBorderPx - rightBorderPx)

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
    ALUI.GUI.Components = ALUI.GUI.Components or {}
    ALUI.GUI.Components.background = setBackground

    -- Store UI components in ALUI namespace
    ALUI.GUI.Components.Left = GUI.Left
    ALUI.GUI.Components.Right = GUI.Right
    ALUI.GUI.Components.Top = GUI.Top
    ALUI.GUI.Styles = ALUI.GUI.Styles or {}
    ALUI.GUI.Styles.BackgroundCSS = GUI.BackgroundCSS
end
