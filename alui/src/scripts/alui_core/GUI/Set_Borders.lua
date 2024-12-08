GUI.setBorders = function()
    local w, h = getMainWindowSize()

    local sideBorder = w * .25

    setBorderLeft(sideBorder)
    setBorderTop(h / 20)
    setBorderBottom(0)
    setBorderRight(sideBorder)
end
