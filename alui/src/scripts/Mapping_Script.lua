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
map.configs.auto_reconcile = map.configs.auto_reconcile ~= false
map.configs.auto_grid_mode = map.configs.auto_grid_mode or false
map.configs.area_auto_grid = map.configs.area_auto_grid or {}
map.configs.debug_mapper = map.configs.debug_mapper == true

-- FIFO queue for GMCP room events — prevents data loss during fast movement.
-- Each entry is a deep-copied snapshot captured at event-receive time so that
-- rapid movement (multiple rooms per network batch) doesn't overwrite data
-- before handle_move() gets a chance to run.
local room_event_queue = {}
local queue_processing = false
local queue_drain_timer = nil

local function debug_echo(message)
    if map.configs.debug_mapper then
        echo(message)
    end
end

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
    ["unvisited"] = { id = 46, r = 50, g = 50, b = 50 }, -- light grey placeholder
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

local grid_mode_terrain_names = {
    ["plains"] = true,
    ["light forest"] = true,
    ["dense forest"] = true,
    ["hills"] = true,
    ["mountains"] = true,
    ["lake"] = true,
    ["under the lake"] = true,
    ["under lake"] = true,
    ["swamp"] = true,
    ["river"] = true,
    ["min river"] = true,
    ["sw river"] = true,
    ["w river"] = true,
    ["nw river"] = true,
    ["n river"] = true,
    ["ne river"] = true,
    ["e river"] = true,
    ["se river"] = true,
    ["s river"] = true,
    ["max river"] = true,
    ["ocean"] = true,
    ["under ocean"] = true,
    ["under the ocean"] = true,
    ["road"] = true,
    ["bridge"] = true,
    ["beach"] = true,
    ["pond"] = true,
    ["tundra"] = true,
}

local function normalize_terrain_name(terrain)
    if type(terrain) ~= "string" then
        return nil
    end
    local value = terrain:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    return string.lower(value)
end

local function room_matches_grid_mode_terrain(roomID)
    if type(roomID) ~= "number" or roomID < 1 then
        return false
    end

    local storedTerrain = normalize_terrain_name(getRoomUserData(roomID, "terrain"))
    if storedTerrain and grid_mode_terrain_names[storedTerrain] then
        return true
    end

    local envID = getRoomEnv(roomID)
    if type(envID) == "number" then
        for terrainName, spec in pairs(terrain_types) do
            if type(spec) == "table" and spec.id == envID then
                local normalized = normalize_terrain_name(terrainName)
                if normalized and grid_mode_terrain_names[normalized] then
                    return true
                end
            end
        end
    end

    if type(map.room_info.vnum) == "string" then
        local currentRoomID = getRoomIDbyHash(map.room_info.vnum)
        if currentRoomID == roomID then
            local currentTerrain = normalize_terrain_name(map.room_info.terrain)
            if currentTerrain and grid_mode_terrain_names[currentTerrain] then
                return true
            end
        end
    end

    return false
end

local function area_has_grid_mode_terrain(areaID)
    if type(areaID) ~= "number" or areaID < 1 then
        return false
    end

    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then
        return false
    end

    for _, roomID in pairs(rooms) do
        if room_matches_grid_mode_terrain(roomID) then
            return true
        end
    end

    return false
end

local function clear_pins_in_area(areaID)
    if type(areaID) ~= "number" or areaID < 1 then
        return 0
    end

    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then
        return 0
    end

    local cleared = 0
    for _, roomID in pairs(rooms) do
        if is_room_pinned(roomID) then
            deleteRoomUserData(roomID, "pinned")
            cleared = cleared + 1
        end
    end

    return cleared
end

local function enforce_area_terrain_policy(areaID, options)
    options = options or {}

    local hasPolicyTerrain = area_has_grid_mode_terrain(areaID)
    local areaKey = tostring(areaID)
    local areaOverride = map.configs.area_auto_grid[areaKey]
    local gridEnabled = (areaOverride ~= nil) and areaOverride or map.configs.auto_grid_mode
    local policyActive = hasPolicyTerrain and gridEnabled
    local pinsCleared = 0
    local gridModeSupported = type(setGridMode) == "function"
    local gridModeApplied = false

    if policyActive and options.clearPins ~= false then
        pinsCleared = clear_pins_in_area(areaID)
    end

    if gridModeSupported and options.applyGrid ~= false then
        if policyActive then
            gridModeApplied = setGridMode(areaID, true) ~= false
        elseif hasPolicyTerrain then
            setGridMode(areaID, false)
        end
    end

    return {
        hasPolicyTerrain = hasPolicyTerrain,
        policyActive = policyActive,
        pinsCleared = pinsCleared,
        gridModeSupported = gridModeSupported,
        gridModeApplied = gridModeApplied,
    }
end

local forced_z_by_terrain_name = {
    ["plains"] = 0,
    ["light forest"] = 0,
    ["dense forest"] = 0,
    ["hills"] = 0,
    ["mountains"] = 0,
    ["lake"] = 0,
    ["swamp"] = 0,
    ["river"] = 0,
    ["ocean"] = 0,
    ["road"] = 0,
    ["bridge"] = 0,
    ["beach"] = 0,
    ["pond"] = 0,
    ["tundra"] = 0,
}

local function get_forced_z_for_room(roomID)
    if type(roomID) ~= "number" or roomID < 1 then
        return nil
    end

    if type(map.room_info.vnum) == "string" then
        local currentRoomID = getRoomIDbyHash(map.room_info.vnum)
        if currentRoomID == roomID then
            local currentTerrain = normalize_terrain_name(map.room_info.terrain)
            local currentForcedZ = currentTerrain and forced_z_by_terrain_name[currentTerrain] or nil
            if type(currentForcedZ) == "number" then
                return currentForcedZ
            end
        end
    end

    local storedTerrain = normalize_terrain_name(getRoomUserData(roomID, "terrain"))
    local storedForcedZ = storedTerrain and forced_z_by_terrain_name[storedTerrain] or nil
    if type(storedForcedZ) == "number" then
        return storedForcedZ
    end

    local envID = getRoomEnv(roomID)
    if type(envID) == "number" then
        for terrainName, spec in pairs(terrain_types) do
            if type(spec) == "table" and spec.id == envID then
                local normalized = normalize_terrain_name(terrainName)
                local forcedZ = normalized and forced_z_by_terrain_name[normalized] or nil
                if type(forcedZ) == "number" then
                    return forcedZ
                end
            end
        end
    end

    return nil
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

-- Returns an iterator over exits in a stable canonical direction order, followed
-- by any remaining exits not covered by the canonical list (e.g. special exits).
-- Using this instead of pairs() ensures BFS traversal is deterministic across
-- runs, which is required for normalize to converge to the same layout every time.
local exit_canonical_order = {
    "north", "northeast", "east", "southeast",
    "south", "southwest", "west", "northwest",
    "up", "down"
}

local function stable_exit_key(value)
    local valueType = type(value)
    if valueType == "number" then
        return "0:" .. tostring(value)
    end
    if valueType == "string" then
        return "1:" .. value
    end
    return "2:" .. tostring(value)
end

local function sorted_exit_pairs(exits)
    if type(exits) ~= "table" then return function() end end
    local result = {}
    local seen = {}
    for _, dir in ipairs(exit_canonical_order) do
        local targetID = exits[dir]
        if targetID ~= nil then
            result[#result + 1] = { dir, targetID }
            seen[dir] = true
        end
    end
    -- Collect unseen exits and sort alphabetically for determinism
    local unseenExits = {}
    for dir, targetID in pairs(exits) do
        if not seen[dir] then
            unseenExits[#unseenExits + 1] = { dir, targetID }
        end
    end
    table.sort(unseenExits, function(a, b)
        return stable_exit_key(a[1]) < stable_exit_key(b[1])
    end)
    for _, entry in ipairs(unseenExits) do
        result[#result + 1] = entry
    end
    local i = 0
    return function()
        i = i + 1
        local entry = result[i]
        if entry then return entry[1], entry[2] end
    end
end

-- Returns true when the area uses grid mode or the current room has outdoor
-- terrain, meaning rooms should never be pushed apart to resolve collisions.
local function should_skip_stretch_for_area(areaID)
    if type(areaID) == "number" and areaID > 0 then
        if map.configs.area_auto_grid[tostring(areaID)] then
            return true
        end
    end
    local terrain = normalize_terrain_name(map.room_info and map.room_info.terrain)
    if terrain and forced_z_by_terrain_name[terrain] ~= nil then
        return true
    end
    return false
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

local function move_room_to_expected_position(roomID, roomHash, areaID, coords, shift, skipStretch)
    -- Never reposition a pinned room.
    if is_room_pinned(roomID) then
        return
    end

    if not skipStretch then
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

    for dir, targetVnum in sorted_exit_pairs(info.exits) do
        if type(targetVnum) == "string" then
            if move_vectors[dir] then
                local shift = move_vectors[dir]
                local coords = { cx + shift[1], cy + shift[2], cz + shift[3] }
                local targetID = getRoomIDbyHash(targetVnum)
                if targetID > 0 then
                    local tx, ty, tz = getRoomCoordinates(targetID)
                    local targetAreaID = getRoomArea(targetID)
                    if map.configs.auto_reconcile and targetAreaID == areaID
                        and (tx ~= coords[1] or ty ~= coords[2] or tz ~= coords[3]) then
                        move_room_to_expected_position(targetID, targetVnum, areaID, coords, shift,
                            should_skip_stretch_for_area(areaID))
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

                    if not sameHashAtTarget and not table.is_empty(overlap) and not should_skip_stretch_for_area(areaID) then
                        stretch_area_for_new_room(areaID, coords, shift)
                    end

                    if targetID < 1 then
                        targetID = createRoomID()
                        addRoom(targetID)
                        setRoomIDbyHash(targetID, targetVnum)
                        setRoomName(targetID, targetVnum)
                        setRoomArea(targetID, areaID)
                        setRoomCoordinates(targetID, coords[1], coords[2], coords[3])
                        setRoomEnv(targetID, terrain_types["unvisited"].id)
                        local currentTerrain = normalize_terrain_name(info.terrain)
                        if currentTerrain and forced_z_by_terrain_name[currentTerrain] ~= nil then
                            setRoomUserData(targetID, "terrain", info.terrain)
                        end
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
                            if not table.is_empty(overlap) and not should_skip_stretch_for_area(areaID) then
                                stretch_area_for_new_room(areaID, targetCoords, guessed)
                            end
                            targetID = createRoomID()
                            addRoom(targetID)
                            setRoomIDbyHash(targetID, targetVnum)
                            setRoomName(targetID, targetVnum)
                            setRoomArea(targetID, areaID)
                            setRoomCoordinates(targetID, targetCoords[1], targetCoords[2], targetCoords[3])
                            setRoomEnv(targetID, terrain_types["unvisited"].id)
                            local currentTerrain = normalize_terrain_name(info.terrain)
                            if currentTerrain and forced_z_by_terrain_name[currentTerrain] ~= nil then
                                setRoomUserData(targetID, "terrain", info.terrain)
                            end
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
            -- map stretching (skip for grid-mode / outdoor-terrain areas)
            if not should_skip_stretch_for_area(areaID) then
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
    end
    local thisRoom = createRoomID()
    addRoom(thisRoom)
    setRoomIDbyHash(thisRoom, info.vnum)
    setRoomName(thisRoom, info.name)
    setRoomArea(thisRoom, areaID)
    setRoomCoordinates(thisRoom, coords[1], coords[2], coords[3])
    apply_room_environment(thisRoom, info.terrain)
    if getRoomChar(thisRoom) == "#" then
        apply_room_environment(thisRoom, "Inside")
    end
    if type(info.terrain) == "string" and info.terrain ~= "" then
        setRoomUserData(thisRoom, "terrain", info.terrain)
    end
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
            move_room_to_expected_position(currentRoomID, map.room_info.vnum, areaID, expected, shift, true)
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
        local passMovedCount = 0 -- Track moves in this pass

        for _, roomID in ipairs(queue) do
            local areaID = getRoomArea(roomID)
            local rx, ry, rz = getRoomCoordinates(roomID)
            local exits = getRoomExits(roomID)

            if areaID and rx ~= nil and ry ~= nil and rz ~= nil and type(exits) == "table" then
                for dir, targetID in sorted_exit_pairs(exits) do
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
                            local tx, ty, tz = getRoomCoordinates(targetID)
                            -- For horizontal exits, preserve the target's current z so that
                            -- flatten_cardinal_connected_rooms has sole authority on elevation
                            -- and the two passes cannot fight each other over z values.
                            -- For vertical exits, apply the full shift so up/down stacking is correct.
                            local expectedZ = (shift[3] == 0) and (tz or rz) or (rz + shift[3])
                            local expected = { rx + shift[1], ry + shift[2], expectedZ }

                            if tx ~= expected[1] or ty ~= expected[2] or tz ~= expected[3] then
                                local targetHash = getRoomHashByID and getRoomHashByID(targetID) or ""
                                move_room_to_expected_position(targetID, targetHash, areaID, expected, shift, true)
                                movedTotal = movedTotal + 1
                                passMovedCount = passMovedCount + 1 -- Count for this pass
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
        -- Early exit: if this pass moved nothing, stop
        if passMovedCount == 0 then
            break
        end
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

    local seedForcedZ = get_forced_z_for_room(seedRoomID)
    if type(seedForcedZ) == "number" then
        sz = seedForcedZ
        local _, _, currentSeedZ = getRoomCoordinates(seedRoomID)
        if currentSeedZ ~= seedForcedZ then
            setRoomCoordinates(seedRoomID, sx, sy, seedForcedZ)
        end
    end

    maxMoves = maxMoves or map.configs.reconcile_deep_max_moves

    -- PHASE 1: Build pinned-room registry
    local pinnedRooms = {} -- { roomID -> z_level }
    local allRooms = getAreaRooms(areaID)

    if type(allRooms) == "table" then
        for _, roomID in ipairs(allRooms) do
            if is_room_pinned(roomID) then
                local _, _, pz = getRoomCoordinates(roomID)
                if pz ~= nil then
                    pinnedRooms[roomID] = pz
                end
            end
        end
    end

    -- PHASE 2: Process rooms with pinned-anchor or seed fallback
    local queue = { { roomID = seedRoomID, ancestorZ = sz } }
    local visited = { [seedRoomID] = true }
    local movedTotal = 0

    while #queue > 0 and movedTotal < maxMoves do
        local nextQueue = {}

        for _, entry in ipairs(queue) do
            local roomID = entry.roomID
            local ancestorZ = entry.ancestorZ
            local roomAreaID = getRoomArea(roomID) or areaID
            local exits = getRoomExits(roomID)
            local rx, ry, rz = getRoomCoordinates(roomID)

            if roomAreaID and rx ~= nil and ry ~= nil and rz ~= nil and type(exits) == "table" then
                for dir, targetID in sorted_exit_pairs(exits) do
                    local shift = get_shift_for_exit_key(dir)
                    if type(targetID) == "string" then
                        targetID = tonumber(targetID)
                    end
                    if is_horizontal_shift(shift) and type(targetID) == "number" and targetID > 0 then
                        local targetAreaID = getRoomArea(targetID)
                        if targetAreaID ~= areaID then
                            if not visited[targetID] then visited[targetID] = true end
                        else
                            local tx, ty, tz = getRoomCoordinates(targetID)

                            -- Determine target's z-level:
                            -- 1. If target is pinned, use its z
                            -- 2. Otherwise use ancestor's z
                            local forcedTargetZ = get_forced_z_for_room(targetID)
                            local targetZ = forcedTargetZ or pinnedRooms[targetID] or ancestorZ
                            local expected = { rx + shift[1], ry + shift[2], targetZ }

                            if tx ~= expected[1] or ty ~= expected[2] or tz ~= expected[3] then
                                local targetHash = getRoomHashByID and getRoomHashByID(targetID) or ""
                                move_room_to_expected_position(targetID, targetHash, roomAreaID, expected, shift, true)
                                movedTotal = movedTotal + 1
                                if movedTotal >= maxMoves then
                                    break
                                end
                            end

                            if not visited[targetID] then
                                visited[targetID] = true
                                -- Pass along either pinned room's z (if target pinned) or ancestor's z (if not)
                                local propagateZ = forcedTargetZ or pinnedRooms[targetID] or ancestorZ
                                table.insert(nextQueue, { roomID = targetID, ancestorZ = propagateZ })
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

    local areaName = get_area_name_by_id(areaID)
    return roomID, areaID, areaName
end

function map.normalize_room_layout(maxPasses, maxMoves)
    local roomID = getRoomIDbyHash(map.room_info.vnum)
    if roomID < 1 then
        echo("Cannot normalize layout: current room is unknown.\n")
        return
    end

    local resolvedMaxPasses = maxPasses or map.configs.reconcile_deep_max_passes
    local resolvedMaxMoves = maxMoves or map.configs.reconcile_deep_max_moves
    local areaID = getRoomArea(roomID)

    if areaID then
        local policy = enforce_area_terrain_policy(areaID, { clearPins = true, applyGrid = true })
        if policy.policyActive then
            local areaName = get_area_name_by_id(areaID) or ("#" .. areaID)
            echo("Terrain grid policy active for area '" .. areaName .. "'.")
            if policy.pinsCleared > 0 then
                echo(" Cleared " .. policy.pinsCleared .. " pin" .. (policy.pinsCleared == 1 and "" or "s") .. ".")
            end
            echo("\n")
            if not policy.gridModeSupported then
                echo("setGridMode is unavailable in this Mudlet version; area grid mode was not changed.\n")
            end
        end
    end

    -- Reconcile runs first to fix x/y for all exits and x/y/z for vertical exits only.
    -- It deliberately preserves a horizontal target's current z so it does not conflict
    -- with flatten.  Flatten runs second and owns z for all cardinally-connected rooms:
    -- starting at the user's location it fans elevation outward, with pinned rooms acting
    -- as elevation anchors so everything cardinally beyond them inherits their z.
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

-- Performs a single-pass BFS coordinate assignment starting from the current room.
-- Unlike normalize (which corrects rooms relative to their existing coordinates over
-- multiple passes), this rebuilds every reachable room's coordinates purely from
-- exit topology: each room is placed at parent_coords + exit_shift.  The first BFS
-- path to reach a room wins, so FIFO order from the seed determines positions.
--
-- When to prefer this over normalize:
--   • Two groups were mapped independently and then linked by exits, leaving one
--     entire group displaced by many units.
--   • Vertical "up/down" stub rooms ended up stacked at z:0 instead of z:±1.
--   • Large y/x coordinate jumps that multi-pass reconcile would take many passes to fix.
--
-- Pinned rooms are never moved; their stored coordinates are used as the base position
-- for computing their neighbors so they act as anchors for the surrounding layout.
function map.recalculate_room_layout()
    local seedID = getRoomIDbyHash(map.room_info.vnum)
    if type(seedID) ~= "number" or seedID < 1 then
        echo("Cannot recalculate: current room is unknown.\n")
        return
    end

    local areaID = getRoomArea(seedID)
    if not areaID then
        echo("Cannot recalculate: current room has no area.\n")
        return
    end

    local sx, sy, sz = getRoomCoordinates(seedID)
    if sx == nil then
        echo("Cannot recalculate: current room has no coordinates.\n")
        return
    end

    -- FIFO queue: each entry carries the coordinates to use as base for that room's exits.
    local queue      = { { id = seedID, x = sx, y = sy, z = sz } }
    local visited    = { [seedID] = true }
    local movedCount = 0

    while #queue > 0 do
        local entry = table.remove(queue, 1)
        local exits = getRoomExits(entry.id)

        if type(exits) == "table" then
            for dir, targetID in sorted_exit_pairs(exits) do
                if type(targetID) == "string" then
                    targetID = tonumber(targetID)
                end

                if type(targetID) == "number" and targetID > 0 and not visited[targetID] then
                    visited[targetID]  = true

                    local shift        = get_shift_for_exit_key(dir)
                    local targetAreaID = getRoomArea(targetID)

                    if shift and targetAreaID == areaID then
                        local tx = entry.x + shift[1]
                        local ty = entry.y + shift[2]
                        local tz = entry.z + shift[3]

                        if is_room_pinned(targetID) then
                            -- Pinned: keep its stored position as base for neighbors.
                            local px, py, pz = getRoomCoordinates(targetID)
                            table.insert(queue, { id = targetID, x = px, y = py, z = pz })
                        else
                            local cx, cy, cz = getRoomCoordinates(targetID)
                            if cx ~= tx or cy ~= ty or cz ~= tz then
                                setRoomCoordinates(targetID, tx, ty, tz)
                                movedCount = movedCount + 1
                            end
                            table.insert(queue, { id = targetID, x = tx, y = ty, z = tz })
                        end
                    end
                end
            end
        end
    end

    updateMap()
    echo("Topology recalculation repositioned " .. movedCount ..
        " room" .. (movedCount == 1 and "" or "s") .. ".\n")
end

function map.pin_room()
    local roomID, areaID = get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot pin: current room is unknown.\n")
        return
    end
    if areaID then
        local policy = enforce_area_terrain_policy(areaID, { clearPins = true, applyGrid = true })
        if policy.policyActive then
            local areaName = get_area_name_by_id(areaID) or ("#" .. areaID)
            echo("Cannot pin room in '" .. areaName .. "': terrain policy enforces grid mode and disallows pins.\n")
            if policy.pinsCleared > 0 then
                echo("Cleared " ..
                    policy.pinsCleared ..
                    " existing pin" .. (policy.pinsCleared == 1 and "" or "s") .. " in this area.\n")
            end
            if not policy.gridModeSupported then
                echo("setGridMode is unavailable in this Mudlet version; area grid mode was not changed.\n")
            end
            return
        end
    end

    setRoomUserData(roomID, "pinned", "true")
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") pinned.\n")
    echo("  map normalize will not move this room but will position neighbors around it.\n")
end

function map.set_poi()
    local roomID = get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot set POI: current room is unknown.\n")
        return
    end
    setRoomChar(roomID, "#")
    apply_room_environment(roomID, "Inside")
    updateMap()
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") marked as POI (#).\n")
end

function map.remove_poi()
    local roomID = get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot remove POI: current room is unknown.\n")
        return
    end
    setRoomChar(roomID, "")
    local terrain = getRoomUserData(roomID, "terrain")
    if type(terrain) == "string" and terrain ~= "" then
        apply_room_environment(roomID, terrain)
    end
    updateMap()
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") POI marker removed.\n")
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

function map.test_normalize_determinism(numRuns)
    numRuns = numRuns or 5

    local roomID = getRoomIDbyHash(map.room_info.vnum)
    if roomID < 1 then
        echo("Cannot test: current room is unknown.\n")
        return
    end

    -- Collect initial snapshots by running normalize multiple times
    local snapshots = {}

    echo("Running map normalize " .. numRuns .. " times to test determinism...\n")

    for runNum = 1, numRuns do
        -- Run normalize
        map.normalize_room_layout()

        -- Snapshot current room state
        local areaID = getRoomArea(roomID)
        if areaID then
            local rooms = getAreaRooms(areaID)
            if type(rooms) == "table" then
                local snapshot = {}
                for _, id in ipairs(rooms) do
                    local x, y, z = getRoomCoordinates(id)
                    if x ~= nil and y ~= nil and z ~= nil then
                        snapshot[id] = { x = x, y = y, z = z }
                    end
                end
                snapshots[runNum] = snapshot
                echo("  Run " .. runNum .. ": captured " .. table.count(snapshot) .. " rooms.\n")
            end
        end
    end

    -- Compare all snapshots
    echo("\nComparing snapshots...\n")
    local allMatch = true
    local firstSnapshot = snapshots[1]

    for runNum = 2, numRuns do
        local currentSnapshot = snapshots[runNum]
        local differences = 0

        for roomID, coords in pairs(firstSnapshot) do
            local currentCoords = currentSnapshot[roomID]
            if not currentCoords then
                echo("  Room " .. roomID .. " missing in run " .. runNum .. "!\n")
                differences = differences + 1
                allMatch = false
            elseif coords.x ~= currentCoords.x or coords.y ~= currentCoords.y or coords.z ~= currentCoords.z then
                echo("  Room " .. roomID .. " differs in run " .. runNum .. ": (" ..
                    coords.x .. "," .. coords.y .. "," .. coords.z .. ") vs (" ..
                    currentCoords.x .. "," .. currentCoords.y .. "," .. currentCoords.z .. ")\n")
                differences = differences + 1
                allMatch = false
            end
        end

        if differences == 0 then
            echo("  Run " .. runNum .. ": MATCH (identical to run 1)\n")
        else
            echo("  Run " .. runNum .. ": " .. differences .. " difference(s)\n")
        end
    end

    echo("\n")
    if allMatch then
        echo("✓ DETERMINISM TEST PASSED: All " .. numRuns .. " runs produced identical layouts.\n")
    else
        echo("✗ DETERMINISM TEST FAILED: Some runs produced different layouts.\n")
    end
end

function map.show_help()
    echo("Map commands:\n\n")
    echo("  map help\n")
    echo("    Show this help text.\n\n")
    echo("  map normalize [maxPasses maxMoves]\n")
    echo("    Reconcile connected exits, then flatten cardinally connected rooms to the current room elevation.\n")
    echo("    Defaults: maxPasses=" ..
        map.configs.reconcile_deep_max_passes .. ", maxMoves=" .. map.configs.reconcile_deep_max_moves .. "\n")
    echo("    Example: map normalize 5 500\n\n")
    echo("  map area-name [new name]\n")
    echo("    Show or set a custom display name for the current area.\n\n")
    echo("  map clear-area-cache\n")
    echo("    Clear the GMCP area cache and remove stale area-key associations.\n")
    echo("    Use this when rooms appear in the wrong area. Re-enter rooms afterwards to rebuild.\n\n")
    echo("  map pin\n")
    echo("    Pin the current room so 'map normalize' never moves it.\n")
    echo("    Pinned rooms act as anchors: normalize positions all connected rooms relative to them.\n")
    echo("    Use this after manually placing a room where you want it (e.g. 3 south and 3 west).\n")
    echo("    NOTE: Pins are disallowed in grid-mode outdoor terrain areas (for example, surface Terrinor).\n\n")
    echo("  map unpin\n")
    echo("    Remove the pin from the current room, allowing normalize to reposition it freely.\n\n")
    echo("  map pins\n")
    echo("    List all pinned rooms in the current area with their coordinates.\n\n")
    echo("  map export\n")
    echo("    Export the visually selected rooms to the clipboard as JSON for sharing or troubleshooting.\n\n")
    echo("  map auto-reconcile\n")
    echo("    Toggle automatic room repositioning on/off (currently " ..
        (map.configs.auto_reconcile and "ON" or "OFF") .. ").\n")
    echo("    When ON (default), rooms are repositioned each move to keep exit vectors consistent.\n")
    echo("    Turn OFF to prevent shuffling when moving between areas. Use 'map normalize' to reposition manually.\n\n")
    echo("  map auto-grid\n")
    echo("    Toggle grid mode for the CURRENT AREA.\n")
    echo("    Grid mode is auto-enabled when you first enter an area with outdoor terrain.\n")
    echo("    Use this command to override the auto-detected setting for the current area.\n")
    echo("    When ON, the area uses grid mode and pins are disallowed.\n")
    echo("    When OFF, grid mode is disabled and pinning is allowed.\n\n")
    echo("  map apply-terrain\n")
    echo("    Apply the current room's terrain type to all unset rooms in the current area.\n")
    echo("    Rooms with no environment (env -1 or 0) inherit the current room's terrain color and type.\n")
    echo("    Rooms that already have an environment but no stored terrain userdata get it back-filled.\n")
    echo("    Only works when the current room's terrain is an outdoor forced-z type (plains, forest, etc).\n\n")
    echo("  map recalculate\n")
    echo("    Rebuild all room coordinates from scratch using exit topology from the current room.\n")
    echo("    Each room is placed at parent-coords + exit-direction. First BFS path to each room wins.\n")
    echo("    More reliable than normalize when large groups of rooms have badly wrong coordinates\n")
    echo("    (e.g. two independently mapped groups linked by exits, or vertical stubs stuck at z:0).\n")
    echo("    Pinned rooms are not moved; their position is used as an anchor for surrounding rooms.\n\n")
    echo("  map set poi\n")
    echo("    Set the current room's symbol to '#' and apply the Inside background color.\n")
    echo("    Useful for marking points of interest (shops, quest givers, etc.) on the map.\n\n")
    echo("  map remove poi\n")
    echo("    Remove the POI marker from the current room and restore its original terrain color.\n\n")
end

function map.apply_area_terrain()
    local roomID, areaID, areaName = get_current_area_context()
    if not areaID then
        echo("Cannot apply terrain: current area is unknown.\n")
        return
    end

    local currentTerrain = normalize_terrain_name(map.room_info.terrain)
    if not currentTerrain or forced_z_by_terrain_name[currentTerrain] == nil then
        echo("Cannot apply terrain: current room's terrain '" ..
            tostring(map.room_info.terrain) .. "' is not a forced-z outdoor type.\n")
        return
    end

    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then
        echo("No rooms found in area '" .. (areaName or ("#" .. areaID)) .. "'.\n")
        return
    end

    -- Build reverse lookup: envID -> terrain name (first match)
    local envToTerrain = {}
    for terrainName, spec in pairs(terrain_types) do
        if type(spec) == "table" and not envToTerrain[spec.id] then
            envToTerrain[spec.id] = terrainName
        end
    end

    local envApplied = 0
    local terrainBackfilled = 0

    for _, rid in pairs(rooms) do
        local envID = getRoomEnv(rid)
        local storedTerrain = getRoomUserData(rid, "terrain")

        if envID == -1 or envID == 0 then
            -- Room has no environment set — apply current room's terrain
            apply_room_environment(rid, map.room_info.terrain)
            setRoomUserData(rid, "terrain", map.room_info.terrain)
            envApplied = envApplied + 1
        elseif type(storedTerrain) ~= "string" or storedTerrain == "" then
            -- Room has an environment but no terrain userdata — back-fill from env
            local reverseName = envToTerrain[envID]
            if reverseName then
                setRoomUserData(rid, "terrain", reverseName)
                terrainBackfilled = terrainBackfilled + 1
            end
        end
    end

    updateMap()
    echo("Area '" .. (areaName or ("#" .. areaID)) .. "': applied terrain to " ..
        envApplied .. " unset room" .. (envApplied == 1 and "" or "s") ..
        ", back-filled terrain data on " .. terrainBackfilled .. " room" ..
        (terrainBackfilled == 1 and "" or "s") .. ".\n")
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

local function handle_move(isLastInBatch)
    -- Default true so direct callers (e.g. map make-room) get full behaviour.
    if isLastInBatch == nil then isLastInBatch = true end
    local info = map.room_info
    if type(info.vnum) ~= "string" then
        return
    end

    if type(info.vnum) == "string" then
        local rnum = getRoomIDbyHash(info.vnum)
        debug_echo("Current room ID: " .. rnum .. "\n")
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
                debug_echo("Moving room " ..
                rnum .. " from area " .. currentAreaID .. " to area " .. correctAreaID .. "\n")
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
            if getRoomChar(rnum) == "#" then
                apply_room_environment(rnum, "Inside")
            end
            -- Update the room name every visit so placeholder rooms (created by
            -- create_neighbors_for_current_room with the hash as their name) get
            -- their real GMCP name the first time the player actually enters them.
            if type(info.name) == "string" and info.name ~= "" then
                setRoomName(rnum, info.name)
            end
            if type(info.terrain) == "string" and info.terrain ~= "" then
                setRoomUserData(rnum, "terrain", info.terrain)
            end

            -- Auto-enable grid mode for areas with outdoor terrain on first visit
            if currentAreaID and currentAreaID > 0 then
                local areaKey = tostring(currentAreaID)
                if map.configs.area_auto_grid[areaKey] == nil and area_has_grid_mode_terrain(currentAreaID) then
                    map.configs.area_auto_grid[areaKey] = true
                    if type(setGridMode) == "function" then
                        setGridMode(currentAreaID, true)
                    end
                end
            end

            -- TODO: Could this skip calling getExitStubs1 since we have the exists and directions in info.exits? Maybe we can just loop through those instead of calling getExitStubs1 and then looking up directions again?
            -- echo("Room Exits: " .. yajl.to_string(info.exits) .. "\n")

            local stubs = getExitStubs1(rnum)

            debug_echo("Exit stubs for current room: " .. yajl.to_string(stubs) .. "\n")

            if stubs then
                for _, n in ipairs(stubs) do
                    local dir = stubmapFlipped[n]
                    if info.exits and type(info.exits[dir]) == "string" then
                        local targetVnum = info.exits[dir]

                        local id         = getRoomIDbyHash(targetVnum)


                        debug_echo("Processing exit stub in direction '" ..
                            dir .. "' with target room ID: " .. id .. " and a target vnum: " .. targetVnum .. "\n")

                        -- need to see how special exits are represented to handle those properly here
                        if (id > 0) and getRoomName(id) then
                            connectExitStub(rnum, id, dir)
                        end
                    end
                end
            end

            -- create_neighbors runs every room so placeholder rooms exist for
            -- the next queued entry to link against via getRoomIDbyHash.
            create_neighbors_for_current_room(rnum)
            -- Heavy work (reconcile + view centering) only on the last room in
            -- the batch so rapid movement doesn't stall behind per-room BFS.
            if isLastInBatch then
                if map.configs.auto_reconcile then
                    reconcile_connected_rooms(rnum)
                end
                updateMap()
                centerview(rnum)
            end
        end
    end
end

-- Drains room_event_queue in FIFO order, processing each snapshot through
-- handle_move() with correct map.prev_info → map.room_info chaining.
-- Scheduled via tempTimer(0, ...) so all GMCP events from one network batch
-- are captured before processing starts, guaranteeing order.
local function process_room_queue()
    -- Guard against re-entrant calls (shouldn't happen in single-threaded Lua,
    -- but defensive in case a future Mudlet version changes scheduling).
    while #room_event_queue > 0 do
        local snapshot = table.remove(room_event_queue, 1)
        local ok, err = pcall(function()
            map.prev_info = map.room_info
            map.room_info = snapshot
            local isLast = (#room_event_queue == 0)
            handle_move(isLast)
        end)
        if not ok then
            echo("Mapper queue error: " .. tostring(err) .. "\n")
        end
    end
    queue_processing = false
    queue_drain_timer = nil
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
        echo("No path to chosen room found.\n")
        return
    end
    table.insert(walkPath, 1, map.room_info.vnum)
    -- go through dirs to find doors that need opened, etc
    -- add in necessary extra commands to walkDirs table
    local k = 1
    repeat
        local id, dir = walkPath[k], walkDirs[k]
        if exitmap[dir] or short[dir] then
            local mappedDir = exitmap[dir] or dir
            local door = check_doors(id, mappedDir)
            local status = door and door[mappedDir]
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
        echo("No path to chosen room found.\n")
    end
end

function map.eventHandler(event, ...)
    if event == "gmcp.Room.Info" then
        -- Deep-copy the GMCP data immediately. gmcp.Room.Info is a shared global
        -- that Mudlet overwrites with the NEXT room's data between event firings,
        -- so any reference to it after this point would see stale/future data.
        local exits = {}
        if type(gmcp.Room.Info.exits) == "table" then
            for k, v in pairs(gmcp.Room.Info.exits) do
                exits[k] = v
            end
        end
        local snapshot = {
            vnum    = gmcp.Room.Info.vnum,
            area    = gmcp.Room.Info.area,
            name    = gmcp.Room.Info.brief,
            terrain = gmcp.Room.Info.terrain,
            exits   = exits,
        }
        table.insert(room_event_queue, snapshot)
        -- Schedule the drain function on the next timer tick (0 s delay).
        -- All GMCP events fired in the same network batch will be queued
        -- before the timer fires, so process_room_queue sees them all in order.
        if not queue_processing then
            queue_processing = true
            queue_drain_timer = tempTimer(0, function() process_room_queue() end)
        end
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
