--util funcs
function table.flip(tbl)
    local t = {}
    for k, v in pairs(tbl) do
        t[v] = k
    end
    return t
end

--end util funcs

local profileName = getProfileName()

alui              = alui or {}
alui.style        = alui.style or {}
alui.status       = alui.status or {}
alui.health       = alui.health or {}
alui.bleeding     = alui.bleeding or {}
GUI               = GUI or {}
GUI.Menu          = GUI.Menu or {}
GUI.Events        = GUI.Events or {}



GUI.Events.resize = registerNamedEventHandler(profileName, 'alui.events.resize', "sysWindowResizeEvent", function()
    GUI.setBorders()
    GUI.setBackground()
    -- GUI.resizeBoxes()
end, false)
