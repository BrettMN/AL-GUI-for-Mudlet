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

-- Core background setup function
local function setBackground()
    local mainWindowPadding = 6

    if Config.get then
        sideBorderPercent = Config.get("ui.sideBorderPercent", sideBorderPercent)
        topBorderPercent = Config.get("ui.topBorderPercent", topBorderPercent)
        mainWindowPadding = Config.get("ui.mainWindowPadding", mainWindowPadding)
    end

    local width, height = getMainWindowSize()
    local sideBorderPx = (width * (sideBorderPercent / 100)) + mainWindowPadding
    local topBorderPx = (height * (topBorderPercent / 100)) + mainWindowPadding
    local centerWidthPx = math.max(1, width - (sideBorderPx * 2))

    GUI.Left.x = 0
    GUI.Left.y = 0
    GUI.Left.height = containerConfig.fullHeight
    GUI.Left.width = sideBorderPx

    GUI.Right.x = width - sideBorderPx
    GUI.Right.y = 0
    GUI.Right.height = containerConfig.fullHeight
    GUI.Right.width = sideBorderPx

    GUI.Top.x = sideBorderPx
    GUI.Top.y = 0
    GUI.Top.height = topBorderPx
    GUI.Top.width = centerWidthPx

    GUI.Left:show()
    GUI.Right:show()
    GUI.Top:show()
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
