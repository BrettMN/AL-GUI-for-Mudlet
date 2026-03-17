--[[Blizzard's GMCP mapping script, edited]]
-- generic GMCP mapping script for Mudlet
-- by Blizzard. https://worldofpa.in
-- based upon an MSDP script from the Mudlet forums in the generic mapper thread
-- with pieces from the generic mapper script and the mmpkg mapper by breakone9r

map = map or {}
map.room_info = map.room_info or {}
map.prev_info = map.prev_info or {}
map.configs = map.configs or {}
map.configs.speedwalk_delay = 0
map.configs.reconcile_max_passes = map.configs.reconcile_max_passes or 3
map.configs.reconcile_max_moves = map.configs.reconcile_max_moves or 200
map.configs.reconcile_deep_max_passes = map.configs.reconcile_deep_max_passes or 20
map.configs.reconcile_deep_max_moves = map.configs.reconcile_deep_max_moves or 5000
map.configs.area_display_names = map.configs.area_display_names or {}
map.configs.area_ids_by_gmcp = map.configs.area_ids_by_gmcp or {}

local defaults = {
    -- using Geyser to handle the mapper in this, since this is a totally new script
    mapper = { x = 0, y = 0, width = "100%", height = "100%" }
}

local terrain_types = {
    -- used to make rooms of different terrain types have different colors
    -- add a new entry for each terrain type, and set the color with RGB values
    -- each id value must be unique, terrain types not listed here will use mapper default color
    -- not used if you define these in a map XML file
    ["Inside"] = { id = 1, r = 255, g = 0, b = 0 },
    ["plains"] = { id = 19, r = 0, g = 255, b = 0 },
    ["light forest"] = { id = 17, r = 34, g = 139, b = 34 }, -- 'forestgreen'
    ["dense forest"] = { id = 18, r = 0, g = 100, b = 0 },   -- 'darkgreen'
    ["hills"] = { id = 21, r = 218, g = 165, b = 32 },       -- 'goldenrod'
    ["mountains"] = { id = 22, r = 160, g = 82, b = 45 },    -- 'sienna'
    ["lake"] = { id = 23, r = 0, g = 25, b = 167 },
    ["under the lake"] = { id = 23, r = 0, g = 25, b = 167 },
    ["swamp"] = { id = 24, r = 128, g = 0, b = 128 },    -- 'purple'
    ["desert"] = { id = 25, r = 240, g = 230, b = 140 }, -- 'khaki'
    ["min river"] = { id = 26, r = 0, g = 25, b = 167 },
    ["river"] = { id = 27, r = 0, g = 25, b = 167 },
    ["sw river"] = { id = 28, r = 0, g = 25, b = 167 },
    ["w river"] = { id = 29, r = 0, g = 25, b = 167 },
    ["nw river"] = { id = 30, r = 0, g = 25, b = 167 },
    ["n river"] = { id = 31, r = 0, g = 25, b = 167 },
    ["ne river"] = { id = 32, r = 0, g = 25, b = 167 },
    ["e river"] = { id = 33, r = 0, g = 25, b = 167 },
    ["se river"] = { id = 34, r = 0, g = 25, b = 167 },
    ["s river"] = { id = 35, r = 0, g = 25, b = 167 },
    ["max river"] = { id = 36, r = 0, g = 25, b = 167 },
    ["ocean"] = { id = 37, r = 0, g = 0, b = 128 },           -- 'navy'
    ["under ocean"] = { id = 37, r = 0, g = 0, b = 128 },     -- 'navy'
    ["under the ocean"] = { id = 37, r = 0, g = 0, b = 128 }, -- 'navy'
    ["under lake"] = { id = 38, r = 0, g = 25, b = 167 },
    ["under river"] = { id = 39, r = 0, g = 25, b = 167 },
    ["sky"] = { id = 40, r = 135, g = 206, b = 235 },    -- 'skyblue'
    ["road"] = { id = 41, r = 211, g = 211, b = 211 },   -- 'lightgrey'
    ["bridge"] = { id = 42, r = 211, g = 211, b = 211 }, -- 'lightgrey'
    ["beach"] = { id = 43, r = 255, g = 239, b = 213 },  -- 'papayawhip'
    ["pond"] = { id = 44, r = 0, g = 25, b = 167 },
    ["tundra"] = { id = 45, r = 245, g = 245, b = 245 }, -- 'whitesmoke'
}

-- list of possible movement directions and appropriate coordinate changes
local move_vectors = {
    north = { 0, 1, 0 },
    northeast = { 1, 1, 0 },
    east = { 1, 0, 0 },
    southeast = { 1, -1, 0 },
    south = { 0, -1, 0 },
    southwest = { -1, -1, 0 },
    west = { -1, 0, 0 },
    northwest = { -1, 1, 0 },
    up = { 0, 0, 1 },
    down = { 0, 0, -1 }
}

local exitmap = {
    n = 'north',
    ne = 'northeast',
    e = 'east',
    se = 'southeast',
    s = 'south',
    sw = 'southwest',
    w = 'west',
    nw = 'northwest',
    u = 'up',
    d = 'down',
    ["in"] = 'in',
    out = 'out',
    l = 'look'
}

local stubmap = {
    north = 1,
    northeast = 2,
    northwest = 3,
    east = 4,
    west = 5,
    south = 6,
    southeast = 7,
    southwest = 8,
    up = 9,
}

-- Precompute reverse mappings for O(1) lookups
local short = {}
if type(exitmap) == "table" then
    for k, v in pairs(exitmap) do
        short[v] = k
    end
end

-- Cache the flipped stubmap for efficient direction lookups
local stubmapFlipped = {}
for k, v in pairs(stubmap) do
    stubmapFlipped[v] = k
end

-- Lookup table for vertical directions (more efficient than table.contains)
local verticalDirs = { u = true, d = true }

local function apply_room_environment(roomID, terrain)
    local target = terrain_types[terrain]
    if not target then
        return
    end

    if getRoomEnv(roomID) ~= target.id then
        setRoomEnv(roomID, target.id)
    end
end

local reverse_move_vectors = {}
for dir, vec in pairs(move_vectors) do
    for rdir, rvec in pairs(move_vectors) do
        if vec[1] == -rvec[1] and vec[2] == -rvec[2] and vec[3] == -rvec[3] then
            reverse_move_vectors[dir] = rdir
            break
        end
    end
end

local function stretch_area_for_new_room(areaID, coords, shift)
    local overlap = getRoomsByPosition(areaID, coords[1], coords[2], coords[3])
    if table.is_empty(overlap) then
        return
    end

    local rooms = getAreaRooms(areaID)
    local rcoords
    for _, id in ipairs(rooms) do
        rcoords = { getRoomCoordinates(id) }
        for n = 1, 3 do
            if shift[n] ~= 0 and (rcoords[n] - coords[n]) * shift[n] <= 0 then
                rcoords[n] = rcoords[n] - shift[n]
            end
        end
        setRoomCoordinates(id, rcoords[1], rcoords[2], rcoords[3])
    end
end

local function move_room_to_expected_position(roomID, roomHash, areaID, coords, shift)
    local overlap = getRoomsByPosition(areaID, coords[1], coords[2], coords[3])

    if not table.is_empty(overlap) then
        local hasCollision = false
        for _, overlapID in pairs(overlap) do
            if overlapID ~= roomID then
                local overlapHash = getRoomHashByID and getRoomHashByID(overlapID)
                if overlapHash and overlapHash ~= roomHash then
                    hasCollision = true
                    break
                end
            end
        end

        if hasCollision then
            stretch_area_for_new_room(areaID, coords, shift)
        end
    end

    setRoomArea(roomID, areaID)
    setRoomCoordinates(roomID, coords[1], coords[2], coords[3])
end

-- Returns the z-shift implied by a vertical special exit name, or nil if ambiguous.
-- Down is checked before up so that "downstairs" doesn't accidentally match "up".
local function guess_vertical_shift(exitName)
    local lower = string.lower(exitName)
    if lower == "down" or lower == "d"
        or lower:find("downstair", 1, true)
        or lower:find("descend", 1, true) then
        return { 0, 0, -1 }
    end
    if lower == "up" or lower == "u"
        or lower:find("upstair", 1, true)
        or lower:find("ascend", 1, true)
        or lower:find("climb", 1, true) then
        return { 0, 0, 1 }
    end
    return nil
end

local function create_neighbors_for_current_room(currentRoomID)
    local info = map.room_info
    if type(info.exits) ~= "table" then
        return
    end

    local areaID = getRoomArea(currentRoomID)
    if not areaID then
        return
    end

    local cx, cy, cz = getRoomCoordinates(currentRoomID)
    if cx == nil or cy == nil or cz == nil then
        return
    end

    for dir, targetVnum in pairs(info.exits) do
        if type(targetVnum) == "string" then
            if move_vectors[dir] then
                local shift = move_vectors[dir]
                local coords = { cx + shift[1], cy + shift[2], cz + shift[3] }
                local targetID = getRoomIDbyHash(targetVnum)
                if targetID > 0 then
                    local tx, ty, tz = getRoomCoordinates(targetID)
                    if tx ~= coords[1] or ty ~= coords[2] or tz ~= coords[3] then
                        move_room_to_expected_position(targetID, targetVnum, areaID, coords, shift)
                    end
                else
                    local overlap = getRoomsByPosition(areaID, coords[1], coords[2], coords[3])
                    local sameHashAtTarget = false

                    if not table.is_empty(overlap) then
                        for _, overlapID in pairs(overlap) do
                            local overlapHash = getRoomHashByID and getRoomHashByID(overlapID)
                            if overlapHash == targetVnum then
                                sameHashAtTarget = true
                                targetID = overlapID
                                break
                            end
                        end
                    end

                    if not sameHashAtTarget and not table.is_empty(overlap) then
                        stretch_area_for_new_room(areaID, coords, shift)
                    end

                    if targetID < 1 then
                        targetID = createRoomID()
                        addRoom(targetID)
                        setRoomIDbyHash(targetID, targetVnum)
                        setRoomName(targetID, targetVnum)
                        setRoomArea(targetID, areaID)
                        setRoomCoordinates(targetID, coords[1], coords[2], coords[3])
                    end
                end

                setExitStub(currentRoomID, dir, true)
                if targetID > 0 then
                    local reverseDir = reverse_move_vectors[dir]
                    if reverseDir then
                        setExitStub(targetID, reverseDir, true)
                    end
                    connectExitStub(currentRoomID, targetID, dir)
                end
            else
                local targetID = getRoomIDbyHash(targetVnum)
                if targetID > 0 then
                    addSpecialExit(currentRoomID, targetID, dir)
                else
                    -- For special exits with a clear vertical direction, pre-create a placeholder
                    -- room so the player can enter it without triggering an overlapping make_room().
                    local guessed = guess_vertical_shift(dir)
                    if guessed then
                        local targetCoords = { cx + guessed[1], cy + guessed[2], cz + guessed[3] }
                        local overlap = getRoomsByPosition(areaID, targetCoords[1], targetCoords[2], targetCoords[3])
                        local sameHashAtTarget = false
                        if not table.is_empty(overlap) then
                            for _, overlapID in pairs(overlap) do
                                local overlapHash = getRoomHashByID and getRoomHashByID(overlapID)
                                if overlapHash == targetVnum then
                                    sameHashAtTarget = true
                                    targetID = overlapID
                                    break
                                end
                            end
                        end
                        if not sameHashAtTarget then
                            if not table.is_empty(overlap) then
                                stretch_area_for_new_room(areaID, targetCoords, guessed)
                            end
                            targetID = createRoomID()
                            addRoom(targetID)
                            setRoomIDbyHash(targetID, targetVnum)
                            setRoomName(targetID, targetVnum)
                            setRoomArea(targetID, areaID)
                            setRoomCoordinates(targetID, targetCoords[1], targetCoords[2], targetCoords[3])
                        end
                        addSpecialExit(currentRoomID, targetID, dir)
                    else
                        echo("Skipping special exit '" ..
                            dir .. "' because target room vnum '" .. targetVnum .. "' is unknown.\n")
                    end
                end
            end
        end
    end
end

local function resolve_area_id_for_room_info(info)
    local gmcpArea = info and info.area
    if type(gmcpArea) ~= "string" or gmcpArea == "" then
        return nil
    end

    local cachedAreaID = tonumber(map.configs.area_ids_by_gmcp[gmcpArea])
    if cachedAreaID and cachedAreaID > 0 then
        return cachedAreaID
    end

    local areas = getAreaTable()
    local areaID = type(areas) == "table" and areas[gmcpArea] or nil

    if not areaID and type(areas) == "table" then
        for _, id in pairs(areas) do
            local savedKey = getAreaUserData(id, "gmcp_area_key")
            if savedKey == gmcpArea then
                areaID = id
                break
            end
        end
    end

    if not areaID then
        areaID = addAreaName(gmcpArea)
    end

    if type(areaID) == "number" and areaID > 0 then
        map.configs.area_ids_by_gmcp[gmcpArea] = areaID
        setAreaUserData(areaID, "gmcp_area_key", gmcpArea)
        return areaID
    end

    return nil
end

local function make_room()
    local info = map.room_info
    local coords = { 0, 0, 0 }
    local thisRoom = createRoomID()
    addRoom(thisRoom)
    setRoomIDbyHash(thisRoom, info.vnum)
    setRoomName(thisRoom, info.name)
    local areaID = resolve_area_id_for_room_info(info)
    if not areaID then
        echo("Cannot create room: area could not be resolved.\n")
        return
    else
        if type(map.prev_info.vnum) == "string" then
            coords = { getRoomCoordinates(getRoomIDbyHash(map.prev_info.vnum)) }
            local shift = { 0, 0, 0 }
            if type(info.exits) == "table" then
                for k, v in pairs(info.exits) do
                    if v == map.prev_info.vnum and move_vectors[k] then
                        shift = move_vectors[k]
                        break
                    end
                end
            end
            -- Fallback 1: prev room had a directional exit leading to this room.
            if shift[1] == 0 and shift[2] == 0 and shift[3] == 0 then
                if type(map.prev_info.exits) == "table" then
                    for k, v in pairs(map.prev_info.exits) do
                        if v == info.vnum and move_vectors[k] then
                            local rev = reverse_move_vectors[k]
                            if rev then shift = move_vectors[rev] end
                            break
                        end
                    end
                end
            end
            -- Fallback 2: infer vertical offset from the special exit name.
            -- The forward exit (prev→current) implies shift = negated guess.
            -- The back exit (current→prev) implies shift = guess directly.
            if shift[1] == 0 and shift[2] == 0 and shift[3] == 0 then
                if type(map.prev_info.exits) == "table" then
                    for k, v in pairs(map.prev_info.exits) do
                        if v == info.vnum and not move_vectors[k] then
                            local g = guess_vertical_shift(k)
                            if g then shift = { -g[1], -g[2], -g[3] } end
                            break
                        end
                    end
                end
                if shift[1] == 0 and shift[2] == 0 and shift[3] == 0 then
                    if type(info.exits) == "table" then
                        for k, v in pairs(info.exits) do
                            if v == map.prev_info.vnum and not move_vectors[k] then
                                local g = guess_vertical_shift(k)
                                if g then shift = g end
                                break
                            end
                        end
                    end
                end
            end
            -- Fallback 3: no directional clue at all — probe adjacent positions
            -- (z+1, z-1, then cardinal neighbours) to avoid placing on top of prev room.
            if shift[1] == 0 and shift[2] == 0 and shift[3] == 0 then
                local probes = { { 0, 0, 1 }, { 0, 0, -1 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 } }
                for _, probe in ipairs(probes) do
                    local testCoords = { coords[1] + probe[1], coords[2] + probe[2], coords[3] + probe[3] }
                    if table.is_empty(getRoomsByPosition(areaID, testCoords[1], testCoords[2], testCoords[3])) then
                        shift = { -probe[1], -probe[2], -probe[3] }
                        break
                    end
                end
            end
            for n = 1, 3 do
                coords[n] = coords[n] - shift[n]
            end
            -- map stretching
            local overlap = getRoomsByPosition(areaID, coords[1], coords[2], coords[3])
            if not table.is_empty(overlap) then
                local rooms = getAreaRooms(areaID)
                local rcoords
                for _, id in ipairs(rooms) do
                    rcoords = { getRoomCoordinates(id) }
                    for n = 1, 3 do
                        if shift[n] ~= 0 and (rcoords[n] - coords[n]) * shift[n] <= 0 then
                            rcoords[n] = rcoords[n] - shift[n]
                        end
                    end
                    setRoomCoordinates(id, rcoords[1], rcoords[2], rcoords[3])
                end
            end
        end
    end
    setRoomArea(thisRoom, areaID)
    setRoomCoordinates(thisRoom, coords[1], coords[2], coords[3])
    apply_room_environment(thisRoom, info.terrain)
    for dir, id in pairs(info.exits) do
        -- need to see how special exits are represented to handle those properly here
        if type(id) == "string" then
            local rid = getRoomIDbyHash(id)
            setExitStub(thisRoom, dir, true)
            if rid > 0 then
                connectExitStub(thisRoom, rid, dir)
            end
        end
    end
    if thisRoom ~= nil then
        centerview(thisRoom)
    end
end

map.make_room = make_room

local function shift_room(dir)
    if type(map.room_info.vnum) ~= "string" then
        return
    end

    if type(map.room_info.vnum) == "string" then
        local ID = getRoomIDbyHash(map.room_info.vnum)
        local x, y, z = getRoomCoordinates(ID)
        local x1, y1, z1 = table.unpack(move_vectors[dir])
        x = x + x1
        y = y + y1
        z = z + z1
        setRoomCoordinates(ID, x, y, z)
        updateMap()
    end
end

local function reconcile_current_room_position(currentRoomID)
    if type(map.prev_info.vnum) ~= "string" then
        return
    end
    if type(map.room_info.exits) ~= "table" then
        return
    end

    local prevID = getRoomIDbyHash(map.prev_info.vnum)
    if prevID < 1 then
        return
    end

    local shift
    for dir, targetVnum in pairs(map.room_info.exits) do
        if targetVnum == map.prev_info.vnum and move_vectors[dir] then
            shift = move_vectors[dir]
            break
        end
    end

    if not shift then
        return
    end

    local prevX, prevY, prevZ = getRoomCoordinates(prevID)
    local expected = { prevX - shift[1], prevY - shift[2], prevZ - shift[3] }
    local currentX, currentY, currentZ = getRoomCoordinates(currentRoomID)

    if currentX ~= expected[1] or currentY ~= expected[2] or currentZ ~= expected[3] then
        local areaID = getRoomArea(currentRoomID) or getRoomArea(prevID)
        if areaID then
            move_room_to_expected_position(currentRoomID, map.room_info.vnum, areaID, expected, shift)
        end
    end
end

local function reconcile_connected_rooms(seedRoomID, maxPasses, maxMoves)
    if type(seedRoomID) ~= "number" or seedRoomID < 1 then
        return 0
    end

    maxPasses = maxPasses or map.configs.reconcile_max_passes
    maxMoves = maxMoves or map.configs.reconcile_max_moves

    local queue = { seedRoomID }
    local visited = { [seedRoomID] = true }
    local movedTotal = 0
    local pass = 0

    while #queue > 0 and pass < maxPasses and movedTotal < maxMoves do
        pass = pass + 1
        local nextQueue = {}

        for _, roomID in ipairs(queue) do
            local areaID = getRoomArea(roomID)
            local rx, ry, rz = getRoomCoordinates(roomID)
            local exits = getRoomExits(roomID)

            if areaID and rx ~= nil and ry ~= nil and rz ~= nil and type(exits) == "table" then
                for dir, targetID in pairs(exits) do
                    local shift = move_vectors[dir]
                    if shift and type(targetID) == "number" and targetID > 0 then
                        local expected = { rx + shift[1], ry + shift[2], rz + shift[3] }
                        local tx, ty, tz = getRoomCoordinates(targetID)

                        if tx ~= expected[1] or ty ~= expected[2] or tz ~= expected[3] then
                            local targetHash = getRoomHashByID and getRoomHashByID(targetID) or ""
                            move_room_to_expected_position(targetID, targetHash, areaID, expected, shift)
                            movedTotal = movedTotal + 1
                            if movedTotal >= maxMoves then
                                break
                            end
                        end

                        if not visited[targetID] then
                            visited[targetID] = true
                            table.insert(nextQueue, targetID)
                        end
                    end
                end
            end

            if movedTotal >= maxMoves then
                break
            end
        end

        queue = nextQueue
    end

    return movedTotal
end

function map.normalize_room_layout(maxPasses, maxMoves)
    local roomID = getRoomIDbyHash(map.room_info.vnum)
    if roomID < 1 then
        echo("Cannot normalize layout: current room is unknown.\n")
        return
    end

    local moved = reconcile_connected_rooms(
        roomID,
        maxPasses or map.configs.reconcile_deep_max_passes,
        maxMoves or map.configs.reconcile_deep_max_moves
    )
    updateMap()
    echo("Layout normalization moved " .. moved .. " rooms.\n")
end

local function trim_whitespace(value)
    if type(value) ~= "string" then
        return ""
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_area_name_by_id(areaID)
    if type(areaID) ~= "number" or areaID < 1 then
        return nil
    end

    local areas = getAreaTable()
    if type(areas) ~= "table" then
        return nil
    end

    for name, id in pairs(areas) do
        if id == areaID then
            return name
        end
    end

    return nil
end

local function get_current_area_context()
    if type(map.room_info.vnum) ~= "string" then
        return nil, nil, nil
    end

    local roomID = getRoomIDbyHash(map.room_info.vnum)
    if type(roomID) ~= "number" or roomID < 1 then
        return nil, nil, nil
    end

    local areaID = getRoomArea(roomID)
    if type(areaID) ~= "number" or areaID < 1 then
        return roomID, nil, nil
    end

    return roomID, areaID, get_area_name_by_id(areaID)
end

function map.set_current_area_display_name(newName)
    local cleanName = trim_whitespace(newName)
    local _, areaID, areaName = get_current_area_context()
    if not areaID then
        echo("Cannot manage area display name: current area is unknown.\n")
        return
    end

    if cleanName == "" then
        local effectiveName = map.get_area_display_name(areaID) or (areaName or ("#" .. areaID))
        echo("Current area name: " .. (areaName or ("#" .. areaID)) .. "\n")
        echo("Display area name: " .. effectiveName .. "\n")
        return
    end

    map.configs.area_display_names[tostring(areaID)] = cleanName
    if type(map.room_info.area) == "string" and map.room_info.area ~= "" then
        map.configs.area_ids_by_gmcp[map.room_info.area] = areaID
        setAreaUserData(areaID, "gmcp_area_key", map.room_info.area)
    end

    local ok, err = setAreaName(areaID, cleanName)
    if not ok then
        echo("Failed to rename mapper area: " .. tostring(err) .. "\n")
        return
    end

    echo("Area display name set for '" .. (areaName or ("#" .. areaID)) .. "': " .. cleanName .. "\n")
end

function map.get_area_display_name(areaIDOrName)
    local areaID

    if type(areaIDOrName) == "number" then
        areaID = areaIDOrName
    elseif type(areaIDOrName) == "string" then
        local parsed = tonumber(areaIDOrName)
        if parsed then
            areaID = parsed
        else
            local areas = getAreaTable()
            if type(areas) == "table" then
                areaID = areas[areaIDOrName]
            end
        end
    elseif areaIDOrName == nil then
        local _, currentAreaID = get_current_area_context()
        areaID = currentAreaID
    end

    if type(areaID) == "number" and areaID > 0 then
        local displayName = map.configs.area_display_names[tostring(areaID)]
        if type(displayName) == "string" and displayName ~= "" then
            return displayName
        end

        local fallbackAreaName = get_area_name_by_id(areaID)
        if fallbackAreaName then
            return fallbackAreaName
        end
    end

    if type(areaIDOrName) == "string" and areaIDOrName ~= "" then
        return areaIDOrName
    end

    return nil
end

function map.show_help()
    echo("Map commands:\n")
    echo("  map help\n")
    echo("    Show this help text.\n")
    echo("  map normalize [maxPasses maxMoves]\n")
    echo("    Reconcile room coordinates across connected directional exits.\n")
    echo("    Defaults: maxPasses=" ..
        map.configs.reconcile_deep_max_passes .. ", maxMoves=" .. map.configs.reconcile_deep_max_moves .. "\n")
    echo("    Example: map normalize 5 500\n")
    echo("  map area-name [new name]\n")
    echo("    Show or set a custom display name for the current area.\n")
end

local function handle_move()
    local info = map.room_info
    if type(info.vnum) ~= "string" then
        return
    end

    if type(info.vnum) == "string" then
        local rnum = getRoomIDbyHash(info.vnum)
        echo("Current room ID: " .. rnum .. "\n")
        if rnum < 1 then
            make_room()
            rnum = getRoomIDbyHash(info.vnum)
        end

        if rnum > 0 then
            if type(info.area) == "string" and info.area ~= "" then
                local currentAreaID = getRoomArea(rnum)
                if type(currentAreaID) == "number" and currentAreaID > 0 then
                    map.configs.area_ids_by_gmcp[info.area] = currentAreaID
                    setAreaUserData(currentAreaID, "gmcp_area_key", info.area)
                end
            end

            reconcile_current_room_position(rnum)
            apply_room_environment(rnum, info.terrain)
            -- TODO: Could this skip calling getExitStubs1 since we have the exists and directions in info.exits? Maybe we can just loop through those instead of calling getExitStubs1 and then looking up directions again?
            echo("Room Exits: " .. yajl.to_string(info.exits) .. "\n")

            local stubs = getExitStubs1(rnum)

            echo("Exit stubs for current room: " .. yajl.to_string(stubs) .. "\n")

            if stubs then
                for _, n in ipairs(stubs) do
                    local dir = stubmapFlipped[n]
                    if info.exits and type(info.exits[dir]) == "string" then
                        local targetVnum = info.exits[dir]

                        local id         = getRoomIDbyHash(targetVnum)


                        echo("Processing exit stub in direction '" ..
                            dir .. "' with target room ID: " .. id .. " and a target vnum: " .. targetVnum .. "\n")

                        -- need to see how special exits are represented to handle those properly here
                        if (id > 0) and getRoomName(id) then
                            connectExitStub(rnum, id, dir)
                        end
                    end
                end
            end

            create_neighbors_for_current_room(rnum)
            reconcile_connected_rooms(rnum)
            centerview(rnum)
        end
    end
end

local function config()
    -- setting terrain colors
    for k, v in pairs(terrain_types) do
        setCustomEnvColor(v.id, v.r, v.g, v.b, 255)
    end
end

local function check_doors(roomID, exits)
    -- looks to see if there are doors in designated directions
    -- used for room comparison, can also be used for pathing purposes
    if type(exits) == "string" then
        exits = { exits }
    end
    local statuses = {}
    local doors = getDoors(roomID)
    local dir
    for k, v in pairs(exits) do
        dir = short[k] or short[v]
        if verticalDirs[dir] then
            dir = exitmap[dir]
        end
        if not doors[dir] or doors[dir] == 0 then
            return false
        else
            statuses[dir] = doors[dir]
        end
    end
    return statuses
end

local continue_walk, timerID
continue_walk = function(new_room)
    if not walking then
        return
    end
    -- calculate wait time until next command, with randomness
    local wait = map.configs.speedwalk_delay or 0
    if wait > 0 and map.configs.speedwalk_random then
        wait = wait * (1 + math.random(0, 100) / 100)
    end
    -- if no wait after new room, move immediately
    if new_room and map.configs.speedwalk_wait and wait == 0 then
        new_room = false
    end
    -- send command if we don't need to wait
    if not new_room then
        send(table.remove(map.walkDirs, 1))
        -- check to see if we are done
        if #map.walkDirs == 0 then
            walking = false
        end
    end
    -- make tempTimer to send next command if necessary
    if walking and (not map.configs.speedwalk_wait or (map.configs.speedwalk_wait and wait > 0)) then
        if timerID then
            killTimer(timerID)
        end
        timerID = tempTimer(wait, function()
            continue_walk()
        end)
    end
end

function map.speedwalk(roomID, walkPath, walkDirs)
    roomID = roomID or speedWalkPath[#speedWalkPath]
    getPath(map.room_info.vnum, roomID)
    walkPath = speedWalkPath
    walkDirs = speedWalkDir
    if #speedWalkPath == 0 then
        map.echo("No path to chosen room found.", false, true)
        return
    end
    table.insert(walkPath, 1, map.room_info.vnum)
    -- go through dirs to find doors that need opened, etc
    -- add in necessary extra commands to walkDirs table
    local k = 1
    repeat
        local id, dir = walkPath[k], walkDirs[k]
        if exitmap[dir] or short[dir] then
            local door = check_doors(id, exitmap[dir] or dir)
            local status = door and door[dir]
            if status and status > 1 then
                -- if locked, unlock door
                if status == 3 then
                    table.insert(walkPath, k, id)
                    table.insert(walkDirs, k, "unlock " .. (exitmap[dir] or dir))
                    k = k + 1
                end
                -- if closed, open door
                table.insert(walkPath, k, id)
                table.insert(walkDirs, k, "open " .. (exitmap[dir] or dir))
                k = k + 1
            end
        end
        k = k + 1
    until k > #walkDirs
    if map.configs.use_translation then
        for k, v in ipairs(walkDirs) do
            walkDirs[k] = map.configs.lang_dirs[v] or v
        end
    end
    -- perform walk
    walking = true
    if map.configs.speedwalk_wait or map.configs.speedwalk_delay > 0 then
        map.walkDirs = walkDirs
        continue_walk()
    else
        for _, dir in ipairs(walkDirs) do
            send(dir)
        end
        walking = false
    end
end

function doSpeedWalk()
    if #speedWalkPath ~= 0 then
        map.speedwalk(nil, speedWalkPath, speedWalkDir)
    else
        map.echo("No path to chosen room found.", false, true)
    end
end

function map.eventHandler(event, ...)
    if event == "gmcp.Room.Info" then
        echo("\nGMCP Room Info:\n" .. yajl.to_string(gmcp.Room.Info) .. "\n")
        echo("Map Room Info:\n" .. yajl.to_string(map.room_info) .. "\n")

        map.prev_info = map.room_info
        map.room_info = {
            vnum = gmcp.Room.Info.vnum,
            area = gmcp.Room.Info.area,
            name = gmcp.Room.Info.brief,
            terrain = gmcp.Room.Info.terrain,
            exits = gmcp.Room.Info.exits
        }
        if type(map.room_info.exits) == "table" then
            for k, v in pairs(map.room_info.exits) do
                map.room_info.exits[k] = v
            end
        end
        handle_move()
    elseif event == "shiftRoom" then
        local args = { ... }
        local dir = exitmap[args[1]] or args[1]
        if not move_vectors[dir] then
            echo("Error: Invalid direction '" .. tostring(args[1]) .. "'.")
        else
            shift_room(dir)
        end
    elseif event == "sysConnectionEvent" then
        config()
    end
end

registerAnonymousEventHandler("gmcp.Room.Info", "map.eventHandler")
registerAnonymousEventHandler("shiftRoom", "map.eventHandler")
registerAnonymousEventHandler("sysConnectionEvent", "map.eventHandler")
