-- Set_Borders.lua - Migrated to ALUI namespace structure
-- Implements border management with new namespace while maintaining backward compatibility

-- Use ALUI namespace if available, with GUI fallback for compatibility
local GUI_NS = (ALUI and ALUI.GUI) or GUI or {}
local Config = (ALUI and ALUI.Config) or {}

-- Core border setting function
local function setBorders()
    local w, h = getMainWindowSize()

    -- Use configuration values if available, otherwise defaults
    local leftBorderPercent = 0.25
    local rightBorderPercent = 0.25
    local topBorderPercent = 1 / 20 -- h/20 = h * (1/20)
    local mainWindowPadding = 6

    if Config.get then
        local defaultSide = (tonumber((Config.get("ui.sideBorderPercent", 25))) or 25) / 100
        leftBorderPercent = defaultSide
        rightBorderPercent = defaultSide
        topBorderPercent = (tonumber((Config.get("ui.topBorderPercent", 5))) or 5) / 100
        mainWindowPadding = tonumber((Config.get("ui.mainWindowPadding", 6))) or 6
    end

    local layout = GUI_NS.Layout
    if layout then
        if tonumber(layout.leftBorderPercent) then
            leftBorderPercent = tonumber(layout.leftBorderPercent) / 100
        end
        if tonumber(layout.rightBorderPercent) then
            rightBorderPercent = tonumber(layout.rightBorderPercent) / 100
        end
    end

    leftBorderPercent = tonumber(leftBorderPercent) or 0.25
    rightBorderPercent = tonumber(rightBorderPercent) or 0.25
    topBorderPercent = tonumber(topBorderPercent) or (1 / 20)

    local leftBorder = (w * leftBorderPercent) + mainWindowPadding
    local rightBorder = (w * rightBorderPercent) + mainWindowPadding
    local topBorder = (h * topBorderPercent) + mainWindowPadding

    setBorderLeft(leftBorder)
    setBorderTop(topBorder)
    setBorderBottom(mainWindowPadding)
    setBorderRight(rightBorder)
end

-- Register function in both namespaces for compatibility
GUI_NS.setBorders = setBorders

-- Also register in legacy GUI namespace for backward compatibility
if GUI then
    GUI.setBorders = setBorders
end

-- Register in new ALUI namespace if available
if ALUI and ALUI.GUI then
    ALUI.GUI.setBorders = setBorders
end
