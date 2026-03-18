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
    down = 10,
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

local function is_horizontal_shift(shift)
    return type(shift) == "table" and shift[3] == 0
end

local function is_room_pinned(roomID)
    return getRoomUserData(roomID, "pinned") == "true"
end

local function normalize_exit_direction(dir)
    if type(dir) == "string" then
        local lower = string.lower(dir)
        if move_vectors[lower] then
            return lower
        end

        local expanded = exitmap[lower]
        if type(expanded) == "string" and move_vectors[expanded] then
            return expanded
        end

        local asNumber = tonumber(dir)
        if asNumber then
            local named = stubmapFlipped[asNumber]
            if type(named) == "string" and move_vectors[named] then
                return named
            end
        end
        return nil
    end

    if type(dir) == "number" then
        local named = stubmapFlipped[dir]
        if type(named) == "string" and move_vectors[named] then
            return named
        end
    end

    return nil
end

local function get_shift_for_exit_key(dir)
    local normalized = normalize_exit_direction(dir)
    if not normalized then
        return nil
    end
    return move_vectors[normalized]
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
    -- Never reposition a pinned room.
    if is_room_pinned(roomID) then
        return
    end

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

    local seedAreaID = getRoomArea(seedRoomID)
    if not seedAreaID then
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
                    local shift = get_shift_for_exit_key(dir)
                    if type(targetID) == "string" then
                        targetID = tonumber(targetID)
                    end
                    if shift and type(targetID) == "number" and targetID > 0 then
                        -- Skip rooms belonging to a different area
                        local targetAreaID = getRoomArea(targetID)
                        if targetAreaID ~= seedAreaID then
                            if not visited[targetID] then
                                visited[targetID] = true
                            end
                        else
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
            end

            if movedTotal >= maxMoves then
                break
            end
        end

        queue = nextQueue
    end

    return movedTotal
end

local function flatten_cardinal_connected_rooms(seedRoomID, maxMoves)
    if type(seedRoomID) ~= "number" or seedRoomID < 1 then
        return 0
    end

    local areaID = getRoomArea(seedRoomID)
    local sx, sy, sz = getRoomCoordinates(seedRoomID)
    if not areaID or sx == nil or sy == nil or sz == nil then
        return 0
    end

    maxMoves = maxMoves or map.configs.reconcile_deep_max_moves

    local queue = { { roomID = seedRoomID, coords = { sx, sy, sz } } }
    local visited = { [seedRoomID] = true }
    local movedTotal = 0

    while #queue > 0 and movedTotal < maxMoves do
        local nextQueue = {}

        for _, entry in ipairs(queue) do
            local roomID = entry.roomID
            local coords = entry.coords
            local roomAreaID = getRoomArea(roomID) or areaID
            local exits = getRoomExits(roomID)

            if roomAreaID and type(exits) == "table" then
                for dir, targetID in pairs(exits) do
                    local shift = get_shift_for_exit_key(dir)
                    if type(targetID) == "string" then
                        targetID = tonumber(targetID)
                    end
                    if is_horizontal_shift(shift) and type(targetID) == "number" and targetID > 0 then
                        -- Skip rooms belonging to a different area
                        local targetAreaID = getRoomArea(targetID)
                        if targetAreaID == areaID then
                            local expected = { coords[1] + shift[1], coords[2] + shift[2], sz }
                            local tx, ty, tz = getRoomCoordinates(targetID)

                            if tx ~= expected[1] or ty ~= expected[2] or tz ~= expected[3] then
                                local targetHash = getRoomHashByID and getRoomHashByID(targetID) or ""
                                move_room_to_expected_position(targetID, targetHash, roomAreaID, expected, shift)
                                movedTotal = movedTotal + 1
                                if movedTotal >= maxMoves then
                                    break
                                end
                            end

                            if not visited[targetID] then
                                visited[targetID] = true
                                -- If this room is pinned, propagate BFS from its actual position
                                -- so rooms beyond it are placed relative to where it really sits.
                                local propagateCoords
                                if is_room_pinned(targetID) then
                                    propagateCoords = { tx, ty, tz }
                                else
                                    propagateCoords = expected
                                end
                                table.insert(nextQueue, { roomID = targetID, coords = propagateCoords })
                            end
                        else
                            if not visited[targetID] then
                                visited[targetID] = true
                            end
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

    local resolvedMaxPasses = maxPasses or map.configs.reconcile_deep_max_passes
    local resolvedMaxMoves = maxMoves or map.configs.reconcile_deep_max_moves

    -- Reconcile runs first to apply general x/y/z positioning via cumulative exit shifts.
    -- Flatten runs second so it has final authority on z for all cardinally-connected rooms,
    -- overriding any incorrect z values that reconcile may have propagated via vertical paths.
    local reconcileMoved = reconcile_connected_rooms(roomID, resolvedMaxPasses, resolvedMaxMoves)
    local remainingMoves = math.max(resolvedMaxMoves - reconcileMoved, 0)
    local cardinalMoved = 0

    if remainingMoves > 0 then
        cardinalMoved = flatten_cardinal_connected_rooms(roomID, remainingMoves)
    end

    local moved = reconcileMoved + cardinalMoved
    updateMap()
    echo(
        "Layout normalization moved " .. moved .. " rooms (" .. cardinalMoved .. " cardinal elevation fixes).\n"
    )
end

-- Returns a list of components, where each component is a list of roomIDs.
-- Two rooms are in the same component if they are reachable from each other via
-- horizontal exits only (cardinal and diagonal, z-shift == 0).
-- Vertical and special exits are excluded so that layered areas (e.g. bridge
-- above + path below) end up in separate components.
local function build_horizontal_components(areaID)
    local rooms = getAreaRooms(areaID)
    if not rooms or #rooms == 0 then
        return {}
    end

    local adj = {}
    for _, roomID in ipairs(rooms) do
        adj[roomID] = adj[roomID] or {}
        local exits = getRoomExits(roomID)
        if type(exits) == "table" then
            for dir, targetID in pairs(exits) do
                local shift = get_shift_for_exit_key(dir)
                if type(targetID) == "string" then
                    targetID = tonumber(targetID)
                end
                if is_horizontal_shift(shift) and type(targetID) == "number" and targetID > 0 then
                    if getRoomArea(targetID) == areaID then
                        adj[roomID][targetID] = true
                    end
                end
            end
        end
    end

    local visited = {}
    local components = {}
    for _, startID in ipairs(rooms) do
        if not visited[startID] then
            local component = {}
            local queue = { startID }
            visited[startID] = true
            while #queue > 0 do
                local cur = table.remove(queue, 1)
                table.insert(component, cur)
                for neighbor in pairs(adj[cur] or {}) do
                    if not visited[neighbor] then
                        visited[neighbor] = true
                        table.insert(queue, neighbor)
                    end
                end
            end
            table.insert(components, component)
        end
    end

    return components
end

-- Returns a table mapping "x,y,z" keys to the list of roomIDs at that position,
-- only for positions occupied by more than one room.
local function find_overlap_positions(areaID)
    local rooms = getAreaRooms(areaID)
    if not rooms or #rooms == 0 then
        return {}
    end

    local byPos = {}
    for _, roomID in ipairs(rooms) do
        local x, y, z = getRoomCoordinates(roomID)
        if x ~= nil and y ~= nil and z ~= nil then
            local key = x .. "," .. y .. "," .. z
            byPos[key] = byPos[key] or {}
            table.insert(byPos[key], roomID)
        end
    end

    local overlaps = {}
    for key, ids in pairs(byPos) do
        if #ids > 1 then
            overlaps[key] = ids
        end
    end

    return overlaps
end

-- Separates overlapping horizontal layers within the current area.
-- Each horizontally-connected component is treated as a distinct layer.
-- The largest component (by room count) keeps its z-values; smaller components
-- that participate in overlaps are shifted vertically to a clear z-slot.
function map.separate_overlaps()
    local _, areaID, areaName = get_current_area_context()
    if not areaID then
        echo("Cannot separate overlaps: current area is unknown.\n")
        return
    end

    local overlaps = find_overlap_positions(areaID)
    if not next(overlaps) then
        echo("No overlapping rooms found in '" .. (areaName or ("#" .. areaID)) .. "'.\n")
        return
    end

    local overlapCount = 0
    for _ in pairs(overlaps) do
        overlapCount = overlapCount + 1
    end
    echo("Found " .. overlapCount .. " overlapping position(s) in '" ..
        (areaName or ("#" .. areaID)) .. "'. Separating...\n")

    local components = build_horizontal_components(areaID)

    local roomToComp = {}
    for i, comp in ipairs(components) do
        for _, roomID in ipairs(comp) do
            roomToComp[roomID] = i
        end
    end

    -- Determine which components are involved in at least one overlapping position.
    local involvedComps = {}
    for _, ids in pairs(overlaps) do
        for _, roomID in ipairs(ids) do
            local ci = roomToComp[roomID]
            if ci then
                involvedComps[ci] = true
            end
        end
    end

    -- Sort involved components largest-first; the largest keeps its current z.
    local sortedComps = {}
    for i, comp in ipairs(components) do
        if involvedComps[i] then
            table.insert(sortedComps, { index = i, size = #comp, rooms = comp })
        end
    end
    table.sort(sortedComps, function(a, b) return a.size > b.size end)

    if #sortedComps < 2 then
        echo("Overlapping rooms are all in the same horizontal layer; cannot auto-separate.\n")
        echo("Use 'map shift' to manually reposition rooms.\n")
        return
    end

    -- Collect all z-values currently used anywhere in the area.
    local usedZ = {}
    local allRooms = getAreaRooms(areaID)
    for _, roomID in ipairs(allRooms) do
        local _, _, z = getRoomCoordinates(roomID)
        if z ~= nil then
            usedZ[z] = true
        end
    end

    local gap = 2
    local totalMoved = 0
    local layersMoved = 0

    -- Skip index 1 (largest, stays put). Move all others to a clear z-slot.
    for i = 2, #sortedComps do
        local comp = sortedComps[i].rooms

        -- Collect the z-values this component currently occupies.
        local compZ = {}
        local compZSet = {}
        for _, roomID in ipairs(comp) do
            local _, _, z = getRoomCoordinates(roomID)
            if z ~= nil and not compZSet[z] then
                compZSet[z] = true
                compZ[#compZ + 1] = z
            end
        end

        -- Find the smallest vertical offset (trying +gap, -gap, +2*gap, -2*gap, ...)
        -- such that none of (compZ[j] + offset) is already in usedZ.
        local dz = nil
        for attempt = 1, 1000 do
            for _, candidate in ipairs({ attempt * gap, -attempt * gap }) do
                local ok = true
                for _, cz in ipairs(compZ) do
                    if usedZ[cz + candidate] then
                        ok = false
                        break
                    end
                end
                if ok then
                    dz = candidate
                    break
                end
            end
            if dz then break end
        end

        if not dz then
            echo("Could not find a safe z-offset for layer " .. i .. " (skipped).\n")
        else
            for _, roomID in ipairs(comp) do
                local x, y, z = getRoomCoordinates(roomID)
                if x ~= nil and y ~= nil and z ~= nil then
                    local newZ = z + dz
                    setRoomCoordinates(roomID, x, y, newZ)
                    usedZ[newZ] = true
                    totalMoved = totalMoved + 1
                end
            end
            layersMoved = layersMoved + 1
        end
    end

    updateMap()
    echo("Separated " .. totalMoved .. " room" .. (totalMoved == 1 and "" or "s") ..
        " across " .. layersMoved .. " layer" .. (layersMoved == 1 and "" or "s") .. ".\n")
end

function map.pin_room()
    local roomID, areaID = get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot pin: current room is unknown.\n")
        return
    end
    setRoomUserData(roomID, "pinned", "true")
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") pinned.\n")
    echo("  map normalize will not move this room but will position neighbors around it.\n")
end

function map.unpin_room()
    local roomID, areaID = get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot unpin: current room is unknown.\n")
        return
    end
    deleteRoomUserData(roomID, "pinned")
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") unpinned.\n")
end

function map.list_pins()
    local _, areaID, areaName = get_current_area_context()
    if not areaID then
        echo("Cannot list pins: current area is unknown.\n")
        return
    end

    local rooms = getAreaRooms(areaID)
    if not rooms or #rooms == 0 then
        echo("No rooms in current area.\n")
        return
    end

    local pinned = {}
    for _, roomID in ipairs(rooms) do
        if is_room_pinned(roomID) then
            local x, y, z = getRoomCoordinates(roomID)
            table.insert(pinned, {
                id = roomID,
                name = getRoomName(roomID) or "unknown",
                x = x,
                y = y,
                z = z
            })
        end
    end

    if #pinned == 0 then
        echo("No pinned rooms in '" .. (areaName or ("#" .. areaID)) .. "'.\n")
        return
    end

    echo(#pinned .. " pinned room" .. (#pinned == 1 and "" or "s") ..
        " in '" .. (areaName or ("#" .. areaID)) .. "':\n")
    for _, r in ipairs(pinned) do
        echo("  [" .. r.id .. "] " .. r.name ..
            " at (" .. r.x .. ", " .. r.y .. ", " .. r.z .. ")\n")
    end
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

function map.clear_area_cache()
    -- Clear the in-memory GMCP-area-to-id cache.
    map.configs.area_ids_by_gmcp = {}

    -- Remove stale gmcp_area_key userdata from areas where the stored key no
    -- longer corresponds to any area display name in the area table.  This
    -- cleans up entries that were incorrectly stamped onto the wrong area by
    -- the cache-poisoning bug (where the cache was written before the area
    -- correction ran).  If you have manually-renamed areas whose original
    -- GMCP key was a hash, re-enter any room in those areas to rebuild the
    -- association automatically.
    local areas = getAreaTable()
    if type(areas) == "table" then
        local removed = 0
        for name, id in pairs(areas) do
            local savedKey = getAreaUserData(id, "gmcp_area_key")
            if type(savedKey) == "string" and savedKey ~= "" then
                -- The key is stale when the area's display name is not the key
                -- AND no area in the table has that key as its display name.
                if name ~= savedKey and not areas[savedKey] then
                    deleteAreaUserData(id, "gmcp_area_key")
                    removed = removed + 1
                end
            end
        end
        echo("Area cache cleared. Removed " .. removed .. " stale gmcp_area_key entry" ..
            (removed == 1 and "" or "s") .. ".\n")
        echo("Re-enter rooms in each area to rebuild associations.\n")
    else
        echo("Area cache cleared (could not read area table for userdata cleanup).\n")
    end
end

function map.show_help()
    echo("Map commands:\n")
    echo("  map help\n")
    echo("    Show this help text.\n")
    echo("  map normalize [maxPasses maxMoves]\n")
    echo("    Flatten cardinally connected rooms to the current room elevation, then reconcile connected exits.\n")
    echo("    Defaults: maxPasses=" ..
        map.configs.reconcile_deep_max_passes .. ", maxMoves=" .. map.configs.reconcile_deep_max_moves .. "\n")
    echo("    Example: map normalize 5 500\n")
    echo("  map area-name [new name]\n")
    echo("    Show or set a custom display name for the current area.\n")
    echo("  map clear-area-cache\n")
    echo("    Clear the GMCP area cache and remove stale area-key associations.\n")
    echo("    Use this when rooms appear in the wrong area. Re-enter rooms afterwards to rebuild.\n")
    echo("  map separate\n")
    echo("    Separate overlapping horizontal layers in the current area by shifting each layer to a unique z-level.\n")
    echo("    Useful when a path under a bridge or through a tunnel ends up stacked on top of the road above.\n")
    echo("    The largest layer keeps its position; smaller overlapping layers are shifted vertically.\n")
    echo("  map pin\n")
    echo("    Pin the current room so 'map normalize' never moves it.\n")
    echo("    Pinned rooms act as anchors: normalize positions all connected rooms relative to them.\n")
    echo("    Use this after manually placing a room where you want it (e.g. 3 south and 3 west).\n")
    echo("  map unpin\n")
    echo("    Remove the pin from the current room, allowing normalize to reposition it freely.\n")
    echo("  map pins\n")
    echo("    List all pinned rooms in the current area with their coordinates.\n")
    echo("  map export\n")
    echo("    Export the visually selected rooms to the clipboard as JSON for sharing or troubleshooting.\n")
end

function map.export_rooms()
    local selection = getMapSelection()
    local roomIDs = selection and selection.rooms
    if type(roomIDs) ~= "table" or #roomIDs == 0 then
        echo("No rooms selected. Select rooms on the mapper first, then run 'map export'.\n")
        return
    end

    local result = {}
    for _, roomID in ipairs(roomIDs) do
        local areaID = getRoomArea(roomID)
        local x, y, z = getRoomCoordinates(roomID)
        local exits = getRoomExits(roomID)
        local specialExits = getSpecialExitsSwap(roomID)
        local doors = getDoors(roomID)
        local userData = getAllRoomUserData(roomID)

        -- Convert numeric exit keys to direction names for readability
        local namedExits = {}
        if type(exits) == "table" then
            for k, v in pairs(exits) do
                local dirName = type(k) == "number" and (stubmapFlipped[k] or tostring(k)) or k
                namedExits[dirName] = v
            end
        end

        result[#result + 1] = {
            id            = roomID,
            hash          = getRoomHashByID and getRoomHashByID(roomID) or nil,
            name          = getRoomName(roomID),
            x             = x,
            y             = y,
            z             = z,
            area_id       = areaID,
            area_name     = get_area_name_by_id(areaID),
            environment   = getRoomEnv(roomID),
            exits         = namedExits,
            special_exits = (type(specialExits) == "table" and next(specialExits) ~= nil) and specialExits or nil,
            doors         = (type(doors) == "table" and next(doors) ~= nil) and doors or nil,
            user_data     = (type(userData) == "table" and next(userData) ~= nil) and userData or nil,
        }
    end

    local json = yajl.to_string(result)
    setClipboardText(json)
    echo("Exported " .. #result .. " room" .. (#result == 1 and "" or "s") .. " to clipboard.\n")
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
            -- Check if room needs to be moved to its correct area.
            -- This must run BEFORE updating the cache, so resolve_area_id_for_room_info()
            -- performs a full lookup rather than short-circuiting on a stale cached value.
            -- Placeholder rooms created as exits may be in a different area than their actual area.
            local correctAreaID = resolve_area_id_for_room_info(info)
            local currentAreaID = getRoomArea(rnum)
            if correctAreaID and correctAreaID > 0 and correctAreaID ~= currentAreaID then
                echo("Moving room " .. rnum .. " from area " .. currentAreaID .. " to area " .. correctAreaID .. "\n")
                setRoomArea(rnum, correctAreaID)
                currentAreaID = correctAreaID
            end

            -- Update the cache with the confirmed correct area ID.
            if type(info.area) == "string" and info.area ~= "" then
                if type(currentAreaID) == "number" and currentAreaID > 0 then
                    map.configs.area_ids_by_gmcp[info.area] = currentAreaID
                    setAreaUserData(currentAreaID, "gmcp_area_key", info.area)
                end
            end

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
