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
        local defaultSide = Config.get("ui.sideBorderPercent", 25) / 100
        leftBorderPercent = defaultSide
        rightBorderPercent = defaultSide
        topBorderPercent = Config.get("ui.topBorderPercent", 5) / 100
        mainWindowPadding = Config.get("ui.mainWindowPadding", 6)
    end

    local layout = GUI_NS.Layout
    if layout then
        if tonumber(layout.leftBorderPx) then
            leftBorderPercent = nil
        end
        if tonumber(layout.rightBorderPx) then
            rightBorderPercent = nil
        end
        if leftBorderPercent ~= nil and tonumber(layout.leftBorderPercent) then
            leftBorderPercent = tonumber(layout.leftBorderPercent) / 100
        end
        if rightBorderPercent ~= nil and tonumber(layout.rightBorderPercent) then
            rightBorderPercent = tonumber(layout.rightBorderPercent) / 100
        end
    end

    local leftBorder = (leftBorderPercent and ((w * leftBorderPercent) + mainWindowPadding))
        or (tonumber(layout and layout.leftBorderPx) or ((w * 0.25) + mainWindowPadding))
    local rightBorder = (rightBorderPercent and ((w * rightBorderPercent) + mainWindowPadding))
        or (tonumber(layout and layout.rightBorderPx) or ((w * 0.25) + mainWindowPadding))
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
