GUI.setBorders = function()
    local w, h = getMainWindowSize()

    -- echo("Window size: " .. w .. "x" .. h .. "\n")

    local isSmallScreen = false --w < 1920

    -- echo("Is small screen: " .. tostring(isSmallScreen) .. "\n")

    if isSmallScreen then
        setBorderLeft(w / 10)
        setBorderTop(h / 20)
        setBorderBottom(0)
        setBorderRight(w / 10)
    else
        setBorderLeft(w / 4)
        setBorderTop(h / 20)
        setBorderBottom(0)
        setBorderRight(w / 4)
    end
end
