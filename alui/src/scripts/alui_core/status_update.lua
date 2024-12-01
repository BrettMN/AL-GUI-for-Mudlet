alui.status = alui.status or {}

local fatigue_levels = {
    ["well rested"] = "light_cyan",
    ["barely tired"] = "green",
    ["somewhat tired"] = "green",
    ["winded"] = "green",
    ["tired"] = "green",
    ["weary"] = "light_yellow",
    ["haggard"] = "light_yellow",
    ["worn out"] = "light_yellow",
    ["exhausted"] = "light_yellow",
    ["disoriented"] = "light_red",
    ["faint"] = "light_red",
    ["system shocked"] = "light_red"
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
