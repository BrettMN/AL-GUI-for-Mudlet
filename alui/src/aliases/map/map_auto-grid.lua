-- Toggle auto-grid on a per-area basis
local roomID
if type(map.room_info.vnum) == "string" then
    roomID = getRoomIDbyHash(map.room_info.vnum)
end
if not roomID or roomID <= 0 then
    echo("Auto grid: no current room found. Move to a room first.\n")
    return
end

local areaID = getRoomArea(roomID)
if not areaID then
    echo("Auto grid: could not determine the current area.\n")
    return
end

local areaKey = tostring(areaID)
local areaName = getRoomAreaName(areaID) or ("area " .. areaKey)

-- Determine current effective state and toggle it
local currentOverride = map.configs.area_auto_grid[areaKey]
local currentEffective = (currentOverride ~= nil) and currentOverride or map.configs.auto_grid_mode
local newValue = not currentEffective

map.configs.area_auto_grid[areaKey] = newValue

echo("Auto grid for '" .. areaName .. "' is now " .. (newValue and "ON" or "OFF") .. ".\n")
if newValue then
    echo("  This area will use grid mode when it has outdoor terrain (pins disallowed).\n")
else
    echo("  Grid mode disabled for this area. Pinning is allowed.\n")
end

-- Immediately apply to the current area
if type(setGridMode) == "function" then
    setGridMode(areaID, newValue)
end
