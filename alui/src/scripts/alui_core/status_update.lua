alui.status = alui.status or {}

local alRed = '#830000'
local alBlue = '#2A768C'

local fatigue_levels = {
    ["well rested"] = alBlue,
    ["barely tired"] = "green",
    ["somewhat tired"] = "green",
    ["winded"] = "green",
    ["tired"] = "green",
    ["weary"] = "yellow",
    ["haggard"] = "yellow",
    ["worn out"] = "yellow",
    ["exhausted"] = alRed,
    ["disoriented"] = alRed,
    ["faint"] = "darkred",
    ["system shocked"] = "darkred"
}

function status_update(e)
    if e ~= "gmcp.Char.Status" then
        return
    end

    local status = gmcp.Char.Status

    alui.status.fatigue = fatigue_levels[status.Fatigue]
    GUI.Menu.Fatigue:update()

    alui.status.posture = status.Posture
    GUI.Menu.Posture:update()

    if status.Name and status.Age and status.Race then
        alui.status.meline = "You are " ..
            status.Name:title() .. ", a " .. status.Age .. " year old " .. status.Race .. "."
    end
    raiseEvent("alui status window")
end
