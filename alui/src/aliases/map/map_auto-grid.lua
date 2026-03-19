map.configs.auto_grid_mode = not map.configs.auto_grid_mode
echo("Auto grid mode is now " .. (map.configs.auto_grid_mode and "ON" or "OFF") .. ".\n")
if map.configs.auto_grid_mode then
    echo("  Areas with outdoor terrain will automatically use grid mode (pins disallowed).\n")
else
    echo("  Grid mode will not be applied automatically. Pinning is allowed in all areas.\n")
end

-- Immediately apply to the current area
if type(map.room_info.vnum) == "string" and type(setGridMode) == "function" then
    local roomID = getRoomIDbyHash(map.room_info.vnum)
    if roomID and roomID > 0 then
        local areaID = getRoomArea(roomID)
        if areaID then
            setGridMode(areaID, map.configs.auto_grid_mode)
        end
    end
end
