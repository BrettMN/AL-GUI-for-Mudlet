-- Mapping Script — Helpers
-- Shared utility functions used across Layout, Core, and Commands.
-- All functions are stored in map._ so they are accessible from every file.

map                  = map or {}
map._                = map._ or {}
local _              = map._

-- Direction lookup tables (single-file use, stay local)
local stubmap        = {
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

local stubmapFlipped = {}
for k, v in pairs(stubmap) do
    stubmapFlipped[v] = k
end
-- Expose for use in Core (exit-stub processing) and Commands (export)
_.stubmap                       = stubmap
_.stubmapFlipped                = stubmapFlipped

-- Name patterns that indicate a room is underground.
local underground_name_patterns = {
    "cave", "tunnel", "underground", "beneath", "cavern", "subterranean",
}

-- Name patterns that indicate a room is on an elevated z-level (+1 from surface).
local elevated_name_patterns    = {
    "stone wall",
}

-- Cardinals before diagonals so BFS uses the most meaningful direction for
-- positioning when multiple exits lead to the same room.
local exit_canonical_order      = {
    "north", "east", "south", "west",
    "northeast", "southeast", "southwest", "northwest",
    "up", "down"
}

-- --------------------------------------------------------------------------
-- Environment / terrain helpers
-- --------------------------------------------------------------------------

function _.debug_echo(message)
    if map.configs.debug_mapper then
        echo(message)
    end
end

function _.apply_room_environment(roomID, terrain)
    local target = _.terrain_types[terrain]
    if not target then return end
    if getRoomEnv(roomID) ~= target.id then
        setRoomEnv(roomID, target.id)
    end
end

function _.clear_room_user_data(roomID, key)
    if type(deleteRoomUserData) == "function" then
        deleteRoomUserData(roomID, key)
    else
        setRoomUserData(roomID, key, "")
    end
end

function _.apply_current_room_environment(roomID, terrain)
    -- Elevated rooms (e.g. "Stone wall") ignore the server-sent terrain colour.
    if _.classify_room_elevated(roomID) then
        _.apply_room_environment(roomID, "Inside")
        return
    end
    if type(terrain) == "string" and terrain ~= "" then
        _.apply_room_environment(roomID, terrain)
        return
    end
    local currentEnv   = getRoomEnv(roomID)
    local unvisitedEnv = _.terrain_types["unvisited"] and _.terrain_types["unvisited"].id or nil
    if currentEnv == nil or currentEnv == -1 or currentEnv == 0 or currentEnv == unvisitedEnv then
        _.apply_room_environment(roomID, "Inside")
    end
end

function _.get_room_terrain_name(roomID)
    if type(roomID) ~= "number" or roomID < 1 then return nil end

    local storedTerrain = getRoomUserData(roomID, "terrain")
    if type(storedTerrain) == "string" and storedTerrain ~= "" then
        return storedTerrain
    end

    local envID = getRoomEnv(roomID)
    if type(envID) ~= "number" then return nil end

    return _.envID_to_terrain[envID] or nil
end

-- Returns the mapper room ID of a placeholder that should be adopted for the
-- given arrival, or nil if no adoptable placeholder is found.
--
-- A "placeholder" is a room created by create_neighbors_for_current_room
-- before the player has visited it:  env == unvisited (46) and its name is
-- a bare hash string (no spaces, exactly 32 hex chars) OR it has no linked
-- exits of its own.
--
-- Lookup order:
--  1. The room Mudlet already thinks is the target of prevRoomID's exit in
--     arrivalDir — most reliable, uses Mudlet's own exit table.
--  2. getRoomsByPosition at the expected adjacent coordinate — fallback for
--     cases where the exit hadn't been wired yet.
local function is_placeholder(roomID)
    local unvisitedID = _.terrain_types["unvisited"] and _.terrain_types["unvisited"].id or 46
    if getRoomEnv(roomID) ~= unvisitedID then return false end
    -- Name is the raw hash (32 hex chars, no spaces) — as set in Layout.lua
    local name = getRoomName(roomID) or ""
    if name:match("^[0-9a-f]+$") and #name >= 20 then return true end
    -- No linked exits either way = definitely placeholder
    local exits = getRoomExits(roomID)
    if type(exits) ~= "table" then return true end
    for _ in pairs(exits) do return false end
    return true
end

function _.find_placeholder_for_arrival(prevRoomID, arrivalDir, newVnum)
    if type(prevRoomID) ~= "number" or prevRoomID < 1 then return nil end
    if type(arrivalDir) ~= "string" or arrivalDir == "" then return nil end

    -- Strategy 1: use the exit Mudlet has already wired from prev room.
    local exitTarget = _.get_room_exit_target(prevRoomID, arrivalDir)
    if type(exitTarget) == "number" and exitTarget > 0 then
        -- Only adopt if it is genuinely unvisited (hash-named placeholder).
        if is_placeholder(exitTarget) then
            return exitTarget
        end
        -- The exit is already a real room — don't adopt it.
        return nil
    end

    -- Strategy 2: coordinate scan.
    local shift = _.get_shift_for_exit_key(arrivalDir)
    if not shift then return nil end
    local px, py, pz = getRoomCoordinates(prevRoomID)
    if px == nil then return nil end
    local tx, ty, tz = px + shift[1], py + shift[2], pz + shift[3]
    if type(getRoomsByPosition) ~= "function" then return nil end
    local areaID   = getRoomArea(prevRoomID)
    local nearbyID = getRoomsByPosition(areaID, tx, ty, tz)
    if type(nearbyID) == "number" and nearbyID > 0 and is_placeholder(nearbyID) then
        return nearbyID
    end
    if type(nearbyID) == "table" then
        for _, rid in ipairs(nearbyID) do
            if type(rid) == "number" and rid > 0 and is_placeholder(rid) then
                return rid
            end
        end
    end
    return nil
end

_.find_placeholder_for_arrival = _.find_placeholder_for_arrival

-- Signal that the map has grown during an active autowalk so continue_walk
-- can re-evaluate the route on the next arrival.
function _.mark_autowalk_dirty()
    if map.walking then
        map.autowalk_dirty = true
    end
end

function _.is_horizontal_shift(shift)
    return type(shift) == "table" and shift[3] == 0
end

function _.normalize_terrain_name(terrain)
    if type(terrain) ~= "string" then return nil end
    local value = terrain:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    return string.lower(value)
end

function _.current_room_uses_grid_mode()
    if map.room_info == nil then return false end
    if _.is_elevated_room_name(map.room_info.name) then return false end
    return map.room_info.terrain ~= nil
end

function _.get_forced_z_for_room(roomID)
    if type(roomID) ~= "number" or roomID < 1 then return nil end

    if type(map.room_info.vnum) == "string" then
        local currentRoomID = getRoomIDbyHash(map.room_info.vnum)
        if currentRoomID == roomID then
            local currentTerrain = _.normalize_terrain_name(map.room_info.terrain)
            local currentForcedZ = currentTerrain and _.forced_z_by_terrain_name[currentTerrain] or nil
            if type(currentForcedZ) == "number" then return currentForcedZ end
        end
    end

    local storedTerrain = _.normalize_terrain_name(getRoomUserData(roomID, "terrain"))
    local storedForcedZ = storedTerrain and _.forced_z_by_terrain_name[storedTerrain] or nil
    if type(storedForcedZ) == "number" then return storedForcedZ end

    local envID = getRoomEnv(roomID)
    if type(envID) == "number" then
        local terrainName = _.envID_to_terrain[envID]
        if terrainName then
            local normalized = _.normalize_terrain_name(terrainName)
            local forcedZ = normalized and _.forced_z_by_terrain_name[normalized] or nil
            if type(forcedZ) == "number" then return forcedZ end
        end
    end
    return nil
end

-- --------------------------------------------------------------------------
-- Exit / direction helpers
-- --------------------------------------------------------------------------

function _.normalize_exit_direction(dir)
    if type(dir) == "string" then
        local lower = string.lower(dir)
        if _.move_vectors[lower] then return lower end
        local expanded = _.exitmap[lower]
        if type(expanded) == "string" and _.move_vectors[expanded] then return expanded end
        local asNumber = tonumber(dir)
        if asNumber then
            local named = stubmapFlipped[asNumber]
            if type(named) == "string" and _.move_vectors[named] then return named end
        end
        return nil
    end
    if type(dir) == "number" then
        local named = stubmapFlipped[dir]
        if type(named) == "string" and _.move_vectors[named] then return named end
    end
    return nil
end

function _.get_shift_for_exit_key(dir)
    local normalized = _.normalize_exit_direction(dir)
    if not normalized then return nil end
    return _.move_vectors[normalized]
end

function _.get_room_exit_target(roomID, dir)
    if type(roomID) ~= "number" or roomID < 1 then return nil end
    local exits = getRoomExits(roomID)
    if type(exits) ~= "table" then return nil end
    local normalized = _.normalize_exit_direction(dir) or dir
    local numericDir = type(normalized) == "string" and stubmap[normalized] or nil
    local target = exits[normalized]
    if target == nil and numericDir ~= nil then target = exits[numericDir] end
    if type(target) == "string" then target = tonumber(target) end
    return type(target) == "number" and target or nil
end

function _.room_has_exit_stub(roomID, dir)
    if type(roomID) ~= "number" or roomID < 1 or type(getExitStubs1) ~= "function" then
        return false
    end
    local normalized = _.normalize_exit_direction(dir) or dir
    local numericDir = type(normalized) == "string" and stubmap[normalized] or nil
    if numericDir == nil then return false end
    local stubs = getExitStubs1(roomID)
    if type(stubs) ~= "table" then return false end
    for _, stubDir in ipairs(stubs) do
        if stubDir == numericDir then return true end
    end
    return false
end

function _.ensure_exit_stub(roomID, dir)
    if _.get_room_exit_target(roomID, dir) ~= nil or _.room_has_exit_stub(roomID, dir) then
        return false
    end
    setExitStub(roomID, dir, true)
    return true
end

local function stable_exit_key(value)
    local valueType = type(value)
    if valueType == "number" then return "0:" .. tostring(value) end
    if valueType == "string" then return "1:" .. value end
    return "2:" .. tostring(value)
end

-- Returns an iterator over exits in a stable canonical direction order.
-- Cardinals before diagonals ensures BFS uses the most meaningful direction
-- when multiple exits lead to the same room.
function _.sorted_exit_pairs(exits)
    if type(exits) ~= "table" then return function() end end
    local result = {}
    local seen   = {}
    for _, dir in ipairs(exit_canonical_order) do
        local targetID = exits[dir]
        if targetID ~= nil then
            result[#result + 1] = { dir, targetID }
            seen[dir] = true
        end
    end
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

-- --------------------------------------------------------------------------
-- Room placement helpers
-- --------------------------------------------------------------------------

function _.should_skip_stretch_for_area(areaID)
    return _.current_room_uses_grid_mode()
end

function _.stretch_area_for_new_room(areaID, coords, shift)
    local overlap = getRoomsByPosition(areaID, coords[1], coords[2], coords[3])
    if table.is_empty(overlap) then return end
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

function _.move_room_to_expected_position(roomID, roomHash, areaID, coords, shift, skipStretch)
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
                _.stretch_area_for_new_room(areaID, coords, shift)
            end
        end
    end
    setRoomArea(roomID, areaID)
    setRoomCoordinates(roomID, coords[1], coords[2], coords[3])
end

-- Returns the z-shift implied by a vertical special exit name, or nil.
function _.guess_vertical_shift(exitName)
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

-- --------------------------------------------------------------------------
-- Underground classification
-- --------------------------------------------------------------------------

function _.is_underground_room_name(name)
    if type(name) ~= "string" or name == "" then return false end
    local lower = string.lower(name)
    for _, pattern in ipairs(underground_name_patterns) do
        if lower:find(pattern, 1, true) then return true end
    end
    return false
end

function _.is_elevated_room_name(name)
    if type(name) ~= "string" or name == "" then return false end
    local lower = string.lower(name)
    for _, pattern in ipairs(elevated_name_patterns) do
        if lower:find(pattern, 1, true) then return true end
    end
    return false
end

-- Returns true when the room's name matches an elevated pattern OR when a
-- previous map normalize pass stored the elevationAdjustment property on it.
function _.classify_room_elevated(roomID)
    if _.is_elevated_room_name(getRoomName(roomID)) then return true end
    local adj = getRoomUserData(roomID, "elevationAdjustment")
    return type(adj) == "string" and adj ~= ""
end

function _.classify_room_underground(roomID, parentIsUnderground)
    local name = getRoomName(roomID)
    if _.is_underground_room_name(name) then return true end
    local hash = type(getRoomHashByID) == "function" and getRoomHashByID(roomID) or nil
    if type(hash) == "string" and name == hash then
        return parentIsUnderground
    end
    return false
end

-- --------------------------------------------------------------------------
-- Collision avoidance
-- --------------------------------------------------------------------------

-- Finds the nearest unoccupied position on the same z-level.
-- When an exit-direction shift is provided, positions along that axis are
-- probed first so nudged rooms keep their directional alignment.
function _.find_nearest_unoccupied(occupied, x, y, z, shift, maxRadius)
    -- Cap radius; at r=20 the ring search already covers 1600 candidate positions.
    maxRadius = math.min(maxRadius or 20, 20)

    if type(shift) == "table" then
        local ax, ay = shift[1], shift[2]
        if ax ~= 0 and ay == 0 then
            local dir = ax > 0 and 1 or -1
            for r = 1, maxRadius do
                local key = (x + r * dir) .. "," .. y .. "," .. z
                if not occupied[key] then return x + r * dir, y, z end
                key = (x - r * dir) .. "," .. y .. "," .. z
                if not occupied[key] then return x - r * dir, y, z end
            end
        elseif ay ~= 0 and ax == 0 then
            local dir = ay > 0 and 1 or -1
            for r = 1, maxRadius do
                local key = x .. "," .. (y + r * dir) .. "," .. z
                if not occupied[key] then return x, y + r * dir, z end
                key = x .. "," .. (y - r * dir) .. "," .. z
                if not occupied[key] then return x, y - r * dir, z end
            end
        end
    end

    -- Generic ring search: probe each ring inline without building a table first.
    for r = 1, maxRadius do
        -- Cardinal probes first (4 positions at distance r)
        local candidates = {
            { x, y + r }, { x + r, y }, { x, y - r }, { x - r, y },
        }
        -- Diagonal corners
        candidates[5] = { x + r, y + r }
        candidates[6] = { x + r, y - r }
        candidates[7] = { x - r, y - r }
        candidates[8] = { x - r, y + r }
        -- Fill remaining edge positions
        for i = 1, r - 1 do
            candidates[#candidates + 1] = { x + i, y + r }
            candidates[#candidates + 1] = { x - i, y + r }
            candidates[#candidates + 1] = { x + i, y - r }
            candidates[#candidates + 1] = { x - i, y - r }
            candidates[#candidates + 1] = { x + r, y + i }
            candidates[#candidates + 1] = { x + r, y - i }
            candidates[#candidates + 1] = { x - r, y + i }
            candidates[#candidates + 1] = { x - r, y - i }
        end
        for _, p in ipairs(candidates) do
            local key = p[1] .. "," .. p[2] .. "," .. z
            if not occupied[key] then return p[1], p[2], z end
        end
    end
    return x, y, z
end

-- --------------------------------------------------------------------------
-- Area context helpers
-- --------------------------------------------------------------------------

function _.get_area_name_by_id(areaID)
    if type(areaID) ~= "number" or areaID < 1 then return nil end
    local areas = getAreaTable()
    if type(areas) ~= "table" then return nil end
    for name, id in pairs(areas) do
        if id == areaID then return name end
    end
    return nil
end

function _.get_current_area_context()
    local roomID = nil
    if type(map.room_info.vnum) == "string" then
        roomID = getRoomIDbyHash(map.room_info.vnum)
    end
    if (type(roomID) ~= "number" or roomID < 1) and type(getPlayerRoom) == "function" then
        roomID = getPlayerRoom()
    end
    if type(roomID) ~= "number" or roomID < 1 then return nil, nil, nil end
    local areaID = getRoomArea(roomID)
    if type(areaID) ~= "number" or areaID < 1 then return roomID, nil, nil end
    local areaName = _.get_area_name_by_id(areaID)
    return roomID, areaID, areaName
end
