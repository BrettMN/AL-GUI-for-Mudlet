-- Manually binds the current GMCP vnum to an existing mapper room.
-- Prefers the room currently selected in the mapper; falls back to the
-- room the player is standing in (getPlayerRoom).
local vnum = map.room_info and map.room_info.vnum
if type(vnum) ~= "string" or vnum == "" then
    echo("Cannot link: no current GMCP room data available.\n")
    return
end

local targetID
local selection = type(getMapSelection) == "function" and getMapSelection()
if selection and type(selection.rooms) == "table" and #selection.rooms == 1 then
    targetID = selection.rooms[1]
else
    targetID = type(getPlayerRoom) == "function" and getPlayerRoom() or nil
end

if type(targetID) ~= "number" or targetID < 1 then
    echo("Cannot link: no room selected and player room is unknown.\n")
    echo("Select exactly one room on the mapper first, then run 'map link-room'.\n")
    return
end

local existingHash = type(getRoomHashByID) == "function" and getRoomHashByID(targetID) or nil
if existingHash and existingHash ~= "" and existingHash ~= vnum then
    echo("Room " .. targetID .. " already has a different hash (" .. existingHash .. ").\n")
    echo("Unlink it manually in the mapper before re-linking.\n")
    return
end

setRoomIDbyHash(targetID, vnum)
echo("Linked room " .. targetID .. " (" .. (getRoomName(targetID) or "unknown") .. ") to vnum " .. vnum .. ".\n")
updateMap()
