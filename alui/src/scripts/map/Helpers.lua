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
-- Expose so Layout.lua and Commands.lua can reuse the same definition.
_.is_placeholder = is_placeholder

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

-- --------------------------------------------------------------------------
-- Exit-set scoring and real-room adoption
-- --------------------------------------------------------------------------

-- Returns the exit shift vector from info's perspective back toward prev_info,
-- trying all available fallbacks. Always returns a table of 3 numbers.
function _.discover_exit_shift(info, prev_info)
    local shift = { 0, 0, 0 }
    if type(info.exits) == "table" then
        for k, v in pairs(info.exits) do
            if v == prev_info.vnum and _.move_vectors[k] then
                return _.move_vectors[k]
            end
        end
    end
    if type(prev_info.exits) == "table" then
        for k, v in pairs(prev_info.exits) do
            if v == info.vnum and _.move_vectors[k] then
                local rev = _.reverse_move_vectors[k]
                if rev then return _.move_vectors[rev] end
            end
        end
    end
    if type(prev_info.exits) == "table" then
        for k, v in pairs(prev_info.exits) do
            if v == info.vnum and not _.move_vectors[k] then
                local g = _.guess_vertical_shift(k)
                if g then return { -g[1], -g[2], -g[3] } end
            end
        end
    end
    if type(info.exits) == "table" then
        for k, v in pairs(info.exits) do
            if v == prev_info.vnum and not _.move_vectors[k] then
                local g = _.guess_vertical_shift(k)
                if g then return g end
            end
        end
    end
    return shift
end

-- Counts how many GMCP exit directions in `info` resolve to the same Mudlet
-- room IDs as `rid`'s own exit table.  A higher score = better match.
local function score_exit_match(rid, info)
    if type(info.exits) ~= "table" then return 0 end
    local mapExits = getRoomExits(rid)
    if type(mapExits) ~= "table" then return 0 end
    local score = 0
    for dir, targetVnum in pairs(info.exits) do
        if type(targetVnum) == "string" then
            local targetID = getRoomIDbyHash(targetVnum)
            if type(targetID) == "number" and targetID > 0 then
                local nd = _.normalize_exit_direction(dir)
                if nd then
                    local mapTarget = mapExits[nd]
                    if type(mapTarget) == "string" then mapTarget = tonumber(mapTarget) end
                    if mapTarget == targetID then score = score + 1 end
                end
            end
        end
    end
    return score
end

-- Attempts to find an existing un-hashed real room in areaID that matches
-- the current GMCP room_info by comparing exit sets.
--   Phase 1: positional — compute expected coords from prev room + exit shift;
--            check rooms at that position with score >= 1.
--   Phase 2: area-wide — scan all un-hashed rooms with the same name and pick
--            the unique best scorer with score >= 2 (skip on tie).
-- Returns a room ID or nil.
function _.find_real_room_to_adopt(areaID)
    local info     = map.room_info
    local prevInfo = map.prev_info
    if type(info.name) ~= "string" or info.name == "" then return nil end

    local function is_adoptable(rid)
        local h = type(getRoomHashByID) == "function" and getRoomHashByID(rid) or nil
        return (h == nil or h == "") and not is_placeholder(rid)
    end

    -- Phase 1: positional lookup via prev room + exit direction.
    if type(prevInfo) == "table" and type(prevInfo.vnum) == "string" then
        local prevID = getRoomIDbyHash(prevInfo.vnum)
        if type(prevID) == "number" and prevID > 0 then
            local px, py, pz = getRoomCoordinates(prevID)
            if px ~= nil then
                local shift = _.discover_exit_shift(info, prevInfo)
                local ex = px - shift[1]
                local ey = py - shift[2]
                local ez = pz - shift[3]
                local candidates = getRoomsByPosition(areaID, ex, ey, ez)
                local checkList = {}
                if type(candidates) == "number" and candidates > 0 then
                    checkList = { candidates }
                elseif type(candidates) == "table" then
                    checkList = candidates
                end
                for _, rid in pairs(checkList) do
                    if is_adoptable(rid) and score_exit_match(rid, info) >= 1 then
                        return rid
                    end
                end
            end
        end
    end

    -- Phase 2: area-wide name + exit-set scan.
    local nameLower = string.lower(info.name)
    local rooms     = getAreaRooms(areaID)
    if type(rooms) ~= "table" then return nil end
    local bestID, bestScore, tied = nil, 1, false
    for _, rid in ipairs(rooms) do
        if is_adoptable(rid) then
            local rname = getRoomName(rid)
            if type(rname) == "string" and string.lower(rname) == nameLower then
                local s = score_exit_match(rid, info)
                if s > bestScore then
                    bestID, bestScore, tied = rid, s, false
                elseif s == bestScore and bestID ~= nil then
                    tied = true
                end
            end
        end
    end
    return (not tied) and bestID or nil
end

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

-- --------------------------------------------------------------------------
-- Position cache
-- --------------------------------------------------------------------------
-- Per-call cache mapping "x,y,z" → array of roomIDs in a given area.  Built
-- once at the top of handle_move() and threaded through layout passes so we
-- don't pay an O(area) getRoomsByPosition / getAreaRooms walk per exit on
-- every GMCP Room.Info event (the previous behaviour caused multi-second
-- freezes on large areas).  The cache is mutated in place by setRoomCoordinates
-- / deleteRoom call sites so it stays consistent without rebuilding.

local function pc_key(x, y, z) return x .. "," .. y .. "," .. z end
_.pos_cache_key = pc_key

function _.build_pos_cache(areaID)
    local cache = { _areaID = areaID, _rooms = {} }
    if type(areaID) ~= "number" or areaID < 1 then return cache end
    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then return cache end
    cache._rooms = rooms
    for _, id in ipairs(rooms) do
        local x, y, z = getRoomCoordinates(id)
        if x ~= nil then
            local k = pc_key(x, y, z)
            local list = cache[k]
            if list == nil then
                cache[k] = { id }
            else
                list[#list + 1] = id
            end
        end
    end
    return cache
end

-- Returns the list of roomIDs at (x,y,z), or nil if empty.  Always returns
-- a table when non-nil (call sites can iterate uniformly).
function _.pos_cache_get(cache, x, y, z)
    if cache == nil or x == nil then return nil end
    return cache[pc_key(x, y, z)]
end

function _.pos_cache_add(cache, x, y, z, id)
    if cache == nil or x == nil or id == nil then return end
    local k = pc_key(x, y, z)
    local list = cache[k]
    if list == nil then
        cache[k] = { id }
        return
    end
    for i = 1, #list do if list[i] == id then return end end
    list[#list + 1] = id
end

function _.pos_cache_remove(cache, x, y, z, id)
    if cache == nil or x == nil or id == nil then return end
    local k = pc_key(x, y, z)
    local list = cache[k]
    if list == nil then return end
    for i = 1, #list do
        if list[i] == id then
            table.remove(list, i)
            break
        end
    end
    if #list == 0 then cache[k] = nil end
end

function _.pos_cache_move(cache, oldX, oldY, oldZ, newX, newY, newZ, id)
    if cache == nil or id == nil then return end
    if oldX ~= nil then _.pos_cache_remove(cache, oldX, oldY, oldZ, id) end
    if newX ~= nil then _.pos_cache_add(cache, newX, newY, newZ, id) end
end

-- Drop a room from the cache entirely (used after deleteRoom).  Caller must
-- pass the room's last-known coords — we cannot look them up post-delete.
function _.pos_cache_drop(cache, x, y, z, id)
    if cache == nil then return end
    if x ~= nil and id ~= nil then _.pos_cache_remove(cache, x, y, z, id) end
end

-- --------------------------------------------------------------------------
-- Room lock (pinning manually-placed rooms)
-- --------------------------------------------------------------------------
-- A "locked" room has a user-data flag set to "1".  All layout passes
-- (stretch, reconcile, flatten, recalculate) refuse to move locked rooms,
-- and the dedup passes refuse to delete them.  This lets `map shift`,
-- `map lock`, and external manual placement persist across room updates.

function _.is_room_locked(rid)
    if type(rid) ~= "number" or rid < 1 then return false end
    local v = getRoomUserData(rid, "locked")
    return v == "1"
end

function _.set_room_locked(rid, locked)
    if type(rid) ~= "number" or rid < 1 then return end
    if locked then
        setRoomUserData(rid, "locked", "1")
    else
        if type(clearRoomUserDataItem) == "function" then
            clearRoomUserDataItem(rid, "locked")
        else
            setRoomUserData(rid, "locked", "")
        end
    end
end

-- Returns the Mudlet ID of the room the player is currently in, or nil.
function _.current_player_room_id()
    if type(map.room_info) == "table" and type(map.room_info.vnum) == "string" then
        local id = getRoomIDbyHash(map.room_info.vnum)
        if type(id) == "number" and id > 0 then return id end
    end
    return nil
end

-- A room is "immobile" (cannot be moved by layout passes) if it is locked
-- OR it is the player's current room.  Pinning the player's room avoids the
-- "the room I am in jumped to 0,0,0" symptom when stretch / dedup runs.
function _.is_room_immobile(rid)
    if _.is_room_locked(rid) then return true end
    return rid == _.current_player_room_id()
end

function _.stretch_area_for_new_room(areaID, coords, shift, posCache)
    local overlap = _.pos_cache_get(posCache, coords[1], coords[2], coords[3])
        or getRoomsByPosition(areaID, coords[1], coords[2], coords[3])
    if table.is_empty(overlap) then return end
    local rooms = (posCache and posCache._rooms) or getAreaRooms(areaID)
    local rcoords
    for i, id in ipairs(rooms) do
        if not _.is_room_immobile(id) then
            rcoords = { getRoomCoordinates(id) }
            local ox, oy, oz = rcoords[1], rcoords[2], rcoords[3]
            local moved = false
            for n = 1, 3 do
                if shift[n] ~= 0 and (rcoords[n] - coords[n]) * shift[n] <= 0 then
                    rcoords[n] = rcoords[n] - shift[n]
                    moved = true
                end
            end
            if moved and ox ~= nil then
                setRoomCoordinates(id, rcoords[1], rcoords[2], rcoords[3])
                _.pos_cache_move(posCache, ox, oy, oz,
                    rcoords[1], rcoords[2], rcoords[3], id)
            end
        end
    end
end

function _.move_room_to_expected_position(roomID, roomHash, areaID, coords, shift, skipStretch, posCache)
    -- Locked rooms (and the player's current room) must never be relocated
    -- by neighbour-creation logic.  Just make sure the area assignment is
    -- right and leave coords alone.
    if _.is_room_immobile(roomID) then
        local currentArea = getRoomArea(roomID)
        if currentArea ~= areaID then
            setRoomArea(roomID, areaID)
        end
        return
    end
    if not skipStretch then
        local overlap = _.pos_cache_get(posCache, coords[1], coords[2], coords[3])
            or getRoomsByPosition(areaID, coords[1], coords[2], coords[3])
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
                _.stretch_area_for_new_room(areaID, coords, shift, posCache)
            end
        end
    end
    local currentArea = getRoomArea(roomID)
    if currentArea ~= areaID then setRoomArea(roomID, areaID) end
    local ox, oy, oz = getRoomCoordinates(roomID)
    if ox ~= coords[1] or oy ~= coords[2] or oz ~= coords[3] then
        setRoomCoordinates(roomID, coords[1], coords[2], coords[3])
        _.pos_cache_move(posCache, ox, oy, oz,
            coords[1], coords[2], coords[3], roomID)
    end
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

-- --------------------------------------------------------------------------
-- Layout repair helpers (used by map normalize and map recalculate)
-- --------------------------------------------------------------------------

-- Remove exits from a room that point back to itself (self-loop bugs).
-- Only standard Mudlet direction names are acted on; non-standard exit keys
-- (portals, scripts, etc.) are silently skipped.
-- Returns the number of self-loop exits removed.
function _.strip_self_loop_exits(roomIDs)
    if type(roomIDs) ~= "table" then return 0 end
    local removed = 0
    for _i, rid in ipairs(roomIDs) do
        if type(rid) == "number" and rid > 0 then
            local exits = getRoomExits(rid)
            if type(exits) == "table" then
                for dir, targetID in pairs(exits) do
                    if type(targetID) == "string" then
                        targetID = tonumber(targetID)
                    end
                    if targetID == rid then
                        local nd = _.normalize_exit_direction(dir)
                        if type(nd) == "string" then
                            local ok = pcall(setExit, rid, -1, nd)
                            if ok then
                                removed = removed + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return removed
end

-- Snap vertical room pairs so that sky/elevated rooms sit directly above their
-- ground room and underground rooms sit directly below.
--
-- For each in-area room G with an `up` exit to U where U is also in the area:
--   - If multiple in-area rooms share the same `up` target hash, that violates
--     the global hash-uniqueness rule → counted as shared_target_bug, not moved.
--   - If U is locked or the target cell (gx,gy,gz+1) is already occupied by a
--     different live room → counted as blocked.
--   - Otherwise U is moved to (gx, gy, gz+1).
-- Mirror logic applies for `down` exits (U placed at gz-1).
-- Cross-area exits are ignored entirely.
--
-- Returns { snapped=N, blocked=N, shared_target_bug=N }.
function _.snap_vertical_pair(areaID)
    if type(areaID) ~= "number" or areaID < 1 then
        return { snapped = 0, blocked = 0, shared_target_bug = 0 }
    end
    local areaRooms = getAreaRooms(areaID)
    if type(areaRooms) ~= "table" then
        return { snapped = 0, blocked = 0, shared_target_bug = 0 }
    end

    -- Build a position cache for fast occupancy lookups.
    local posCache = _.build_pos_cache(areaID)

    -- Tally how many in-area rooms point `up` / `down` to each target ID.
    -- More than one in the same direction = shared_target_bug (violates uniqueness).
    local upTargetCount   = {}   -- targetID → count of in-area rooms that exit `up` to it
    local downTargetCount = {}

    for _i, rid in ipairs(areaRooms) do
        local exits = getRoomExits(rid)
        if type(exits) == "table" then
            local up = exits["up"]
            if type(up) == "string" then up = tonumber(up) end
            if type(up) == "number" and up > 0 and getRoomArea(up) == areaID then
                upTargetCount[up] = (upTargetCount[up] or 0) + 1
            end
            local dn = exits["down"]
            if type(dn) == "string" then dn = tonumber(dn) end
            if type(dn) == "number" and dn > 0 and getRoomArea(dn) == areaID then
                downTargetCount[dn] = (downTargetCount[dn] or 0) + 1
            end
        end
    end

    local snapped   = 0
    local blocked   = 0
    local bug_count = 0

    local function try_snap(groundID, targetID, dz)
        -- Skip cross-area exits.
        if getRoomArea(targetID) ~= areaID then return end

        -- Check shared-target bug.
        local tally = dz > 0 and upTargetCount[targetID] or downTargetCount[targetID]
        if (tally or 0) > 1 then
            bug_count = bug_count + 1
            return
        end

        -- Skip locked / immobile targets.
        if _.is_room_immobile(targetID) then
            blocked = blocked + 1
            return
        end

        local gx, gy, gz = getRoomCoordinates(groundID)
        if gx == nil then return end

        local wantX, wantY, wantZ = gx, gy, gz + dz
        local cx, cy, cz = getRoomCoordinates(targetID)
        if cx == wantX and cy == wantY and cz == wantZ then return end -- already correct

        -- Check target cell occupancy.
        local occupants = _.pos_cache_get(posCache, wantX, wantY, wantZ)
        if type(occupants) == "table" then
            for _i, oid in ipairs(occupants) do
                if oid ~= targetID and getRoomArea(oid) == areaID then
                    blocked = blocked + 1
                    return
                end
            end
        end

        setRoomCoordinates(targetID, wantX, wantY, wantZ)
        _.pos_cache_move(posCache, cx, cy, cz, wantX, wantY, wantZ, targetID)
        snapped = snapped + 1
    end

    for _i, rid in ipairs(areaRooms) do
        local exits = getRoomExits(rid)
        if type(exits) == "table" then
            local up = exits["up"]
            if type(up) == "string" then up = tonumber(up) end
            if type(up) == "number" and up > 0 then
                try_snap(rid, up, 1)
            end
            local dn = exits["down"]
            if type(dn) == "string" then dn = tonumber(dn) end
            if type(dn) == "number" and dn > 0 then
                try_snap(rid, dn, -1)
            end
        end
    end

    return { snapped = snapped, blocked = blocked, shared_target_bug = bug_count }
end

-- Read-only audit of layout anomalies for a list of room IDs.
-- Returns a table of bucket counts useful for end-of-run reports:
--   self_loops        — exits whose target is the room itself
--   delta_mismatches  — directional exits where actual coord delta ≠ expected shift
--   vertical_drift    — up/down in-area exits where sky/ground room z is wrong
--   cross_area        — exits that link to a room in a different area
--   shared_target_bug — two+ in-area rooms share the same directional exit target (hash uniqueness violation)
--   duplicate_hash_rooms — multiple mapper IDs resolve to the same GMCP hash
--   unreachable       — rooms in the area with no exits and no exit-stubs pointing at them
--
-- NOTE: This function is intentionally read-only; it never calls setRoomCoordinates or setExit.
function _.audit_layout_anomalies(roomIDs, areaID)
    local counts = {
        self_loops         = 0,
        delta_mismatches   = 0,
        vertical_drift     = 0,
        cross_area         = 0,
        shared_target_bug  = 0,
        duplicate_hash_rooms = 0,
        unreachable        = 0,
    }
    if type(roomIDs) ~= "table" or #roomIDs == 0 then return counts end

    -- Build a set of all roomIDs in scope for quick lookup.
    local inScope = {}
    for _i, rid in ipairs(roomIDs) do inScope[rid] = true end

    -- Tally per-target exit counts within the area to detect shared-target bugs.
    local targetCount = {}  -- targetID → count of (in-scope) sources that exit to it
    for _i, rid in ipairs(roomIDs) do
        local exits = getRoomExits(rid)
        if type(exits) == "table" then
            for dir, targetID in pairs(exits) do
                if type(targetID) == "string" then targetID = tonumber(targetID) end
                if type(targetID) == "number" and targetID > 0 and targetID ~= rid then
                    if not areaID or getRoomArea(targetID) == areaID then
                        local k = tostring(dir) .. "→" .. tostring(targetID)
                        targetCount[k] = (targetCount[k] or 0) + 1
                    end
                end
            end
        end
    end

    -- Check for duplicate hash bindings.
    if type(getRoomHashByID) == "function" then
        local hashSeen = {}
        for _i, rid in ipairs(roomIDs) do
            local h = getRoomHashByID(rid)
            if type(h) == "string" and h ~= "" then
                if hashSeen[h] then
                    counts.duplicate_hash_rooms = counts.duplicate_hash_rooms + 1
                else
                    hashSeen[h] = rid
                end
            end
        end
    end

    -- Rooms that have incoming exits from at least one in-scope room.
    local hasIncoming = {}
    for _i, rid in ipairs(roomIDs) do
        local exits = getRoomExits(rid)
        if type(exits) == "table" then
            for _i, tgt in pairs(exits) do
                if type(tgt) == "string" then tgt = tonumber(tgt) end
                if type(tgt) == "number" and inScope[tgt] then
                    hasIncoming[tgt] = true
                end
            end
        end
    end

    for _i, rid in ipairs(roomIDs) do
        local rx, ry, rz = getRoomCoordinates(rid)
        local exits = getRoomExits(rid)
        local hasAnyExit = false

        if type(exits) == "table" then
            for dir, targetID in pairs(exits) do
                if type(targetID) == "string" then targetID = tonumber(targetID) end
                if type(targetID) == "number" and targetID > 0 then
                    hasAnyExit = true

                    -- Self-loop
                    if targetID == rid then
                        counts.self_loops = counts.self_loops + 1
                    else
                        local targetAreaID = getRoomArea(targetID)

                        -- Cross-area
                        if areaID and type(targetAreaID) == "number" and targetAreaID ~= areaID then
                            counts.cross_area = counts.cross_area + 1
                        else
                            -- Shared-target bug
                            local k = tostring(dir) .. "→" .. tostring(targetID)
                            if (targetCount[k] or 0) > 1 then
                                counts.shared_target_bug = counts.shared_target_bug + 1
                            end

                            -- Delta mismatch
                            local shift = _.get_shift_for_exit_key(dir)
                            if shift and rx ~= nil then
                                local tx, ty, tz = getRoomCoordinates(targetID)
                                if tx ~= nil then
                                    local dx = tx - rx
                                    local dy = ty - ry
                                    local dz = tz - rz
                                    if dx ~= shift[1] or dy ~= shift[2] or dz ~= shift[3] then
                                        -- Distinguish vertical drift from general delta mismatch
                                        local nd = _.normalize_exit_direction(dir)
                                        if (nd == "up" or nd == "down") and dx == 0 and dy == 0 then
                                            counts.vertical_drift = counts.vertical_drift + 1
                                        else
                                            counts.delta_mismatches = counts.delta_mismatches + 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Unreachable: no exits and no in-scope room exits to this room.
        if not hasAnyExit and not hasIncoming[rid] then
            counts.unreachable = counts.unreachable + 1
        end
    end

    return counts
end

-- --------------------------------------------------------------------------
-- De-duplication helpers
-- --------------------------------------------------------------------------

-- Returns a table of groups: each group is a list of roomIDs that share the
-- same non-empty hash.  Only groups with ≥ 2 members are included.
function _.find_duplicate_hash_groups(areaID)
    if type(areaID) ~= "number" or areaID < 1 then return {} end
    if type(getRoomHashByID) ~= "function" then return {} end
    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then return {} end
    local seen   = {}  -- hash → first roomID
    local groups = {}  -- hash → {roomID, ...} (only when dup found)
    for _i, rid in ipairs(rooms) do
        local h = getRoomHashByID(rid)
        if type(h) == "string" and h ~= "" then
            if seen[h] then
                if not groups[h] then
                    groups[h] = { seen[h] }
                end
                groups[h][#groups[h] + 1] = rid
            else
                seen[h] = rid
            end
        end
    end
    local result = {}
    for _i, g in pairs(groups) do
        result[#result + 1] = g
    end
    return result
end

-- Choose which room in a duplicate group should survive.
-- Priority (descending):
--   1. Player's current room or locked room (must not be deleted)
--   2. Most exits (richest connectivity)
--   3. Name is not equal to the room's own hash (real name)
--   4. Has user_data.coord (game-authoritative position)
--   5. Lowest room id (deterministic tiebreaker)
function _.choose_survivor(group)
    if type(group) ~= "table" or #group == 0 then return nil end
    local playerRoom = _.current_player_room_id()
    local best       = nil
    local bestScore  = nil

    for _i, rid in ipairs(group) do
        local score    = {}
        -- criterion 1: immobile (player or locked)
        score[1]       = (rid == playerRoom or _.is_room_locked(rid)) and 1 or 0
        -- criterion 2: exit count
        local exits    = getRoomExits(rid)
        score[2]       = type(exits) == "table" and (function()
            local n = 0; for _ in pairs(exits) do n = n + 1 end; return n
        end)() or 0
        -- criterion 3: name is not the hash string
        local name     = type(getRoomName) == "function" and getRoomName(rid) or ""
        local hash     = type(getRoomHashByID) == "function" and getRoomHashByID(rid) or ""
        score[3]       = (name ~= hash and name ~= "") and 1 or 0
        -- criterion 4: has user_data.coord
        local coord    = getRoomUserData(rid, "coord")
        score[4]       = (type(coord) == "string" and coord ~= "") and 1 or 0
        -- criterion 5: lower id is better (negate for "higher = better" sort)
        score[5]       = -rid

        if bestScore == nil then
            best      = rid
            bestScore = score
        else
            for i = 1, 5 do
                if score[i] > bestScore[i] then
                    best      = rid
                    bestScore = score
                    break
                elseif score[i] < bestScore[i] then
                    break
                end
            end
        end
    end
    return best
end

-- Build a reverse exit index for ALL rooms across all areas:
--   index[targetID] = { {sourceID, kind="normal", dir=...}, {sourceID, kind="special", cmd=...}, ... }
-- Building this once is efficient for batch merges.
local function build_reverse_exit_index(targetIDs)
    local targetSet = {}
    for _i, id in ipairs(targetIDs) do targetSet[id] = true end

    local index = {}
    local allRooms = type(getRooms) == "function" and getRooms() or {}
    for rid in pairs(allRooms) do
        -- Normal exits
        local exits = getRoomExits(rid)
        if type(exits) == "table" then
            for dir, tgt in pairs(exits) do
                if type(tgt) == "string" then tgt = tonumber(tgt) end
                if type(tgt) == "number" and targetSet[tgt] then
                    if not index[tgt] then index[tgt] = {} end
                    index[tgt][#index[tgt] + 1] = { sourceID = rid, kind = "normal", dir = dir }
                end
            end
        end
        -- Special exits (getSpecialExitsSwap returns cmd→targetID)
        if type(getSpecialExitsSwap) == "function" then
            local sp = getSpecialExitsSwap(rid)
            if type(sp) == "table" then
                for cmd, tgt in pairs(sp) do
                    if type(tgt) == "string" then tgt = tonumber(tgt) end
                    if type(tgt) == "number" and targetSet[tgt] then
                        if not index[tgt] then index[tgt] = {} end
                        index[tgt][#index[tgt] + 1] = { sourceID = rid, kind = "special", cmd = cmd }
                    end
                end
            end
        end
    end
    return index
end

-- Merge loserID into survivorID:
--  - Rewrites all inbound exits pointing at loser → survivor (normal + special).
--  - Merges loser's outbound normal exits onto survivor (skip dirs survivor already has).
--  - Merges loser's outbound special exits onto survivor (skip cmds survivor already has).
--  - Copies user_data keys from loser to survivor only when key is missing on survivor.
--  - Clears loser's hash binding so getRoomIDbyHash no longer returns the deleted id.
--  - Drops loser from posCache and deletes it.
-- `revIndex` is the reverse exit index produced by build_reverse_exit_index (optional
-- optimisation — pass nil to build a one-off scan, but that is slow in batch).
function _.merge_duplicate_room(survivorID, loserID, posCache, revIndex)
    if survivorID == loserID then return end
    if type(survivorID) ~= "number" or survivorID < 1 then return end
    if type(loserID) ~= "number" or loserID < 1 then return end

    -- 1. Rewrite inbound exits: normal
    local inboundList = revIndex and (revIndex[loserID] or {}) or (function()
        local tmp = {}
        local idx = build_reverse_exit_index({ loserID })
        for _i, entry in ipairs(idx[loserID] or {}) do tmp[#tmp + 1] = entry end
        return tmp
    end)()

    for _i, entry in ipairs(inboundList) do
        local src = entry.sourceID
        if entry.kind == "normal" then
            local dir = entry.dir
            -- Normalise numeric dir keys to string names (Mudlet sometimes returns ints)
            if type(dir) == "number" then dir = _.stubmapFlipped[dir] end
            if type(dir) == "string" then
                pcall(setExit, src, survivorID, dir)
                -- Preserve door state on the source room's exit direction
                if getDoors and setDoor then
                    local srcDoors = getDoors(src)
                    if type(srcDoors) == "table" and srcDoors[dir] and srcDoors[dir] ~= 0 then
                        pcall(setDoor, src, dir, srcDoors[dir])
                    end
                end
            end
        elseif entry.kind == "special" then
            -- Rewrite the SOURCE room's special exit cmd to point at survivorID
            local src = entry.sourceID
            local cmd = entry.cmd
            if type(addSpecialExit) == "function" and type(clearSpecialExit) == "function" then
                pcall(clearSpecialExit, src, cmd)
                pcall(addSpecialExit, src, survivorID, cmd)
            end
        end
    end

    -- 2. Merge loser's outbound normal exits → survivor
    local loserExits    = getRoomExits(loserID)
    local survivorExits = getRoomExits(survivorID)
    if type(loserExits) == "table" then
        for dir, tgt in pairs(loserExits) do
            if type(tgt) == "string" then tgt = tonumber(tgt) end
            if type(dir) == "number" then dir = _.stubmapFlipped[dir] end
            if type(dir) == "string" and type(tgt) == "number" and tgt > 0 and tgt ~= loserID then
                local survivorHasDir = type(survivorExits) == "table" and survivorExits[dir] ~= nil
                if not survivorHasDir then
                    pcall(setExit, survivorID, tgt, dir)
                    -- Carry door state
                    if getDoors and setDoor then
                        local loserDoors = getDoors(loserID)
                        if type(loserDoors) == "table" and loserDoors[dir] and loserDoors[dir] ~= 0 then
                            pcall(setDoor, survivorID, dir, loserDoors[dir])
                        end
                    end
                end
            end
        end
    end

    -- 3. Merge loser's outbound special exits → survivor
    if type(getSpecialExitsSwap) == "function" and type(addSpecialExit) == "function" then
        local loserSp    = getSpecialExitsSwap(loserID)
        local survivorSp = getSpecialExitsSwap(survivorID)
        if type(loserSp) == "table" then
            for cmd, tgt in pairs(loserSp) do
                if type(tgt) == "string" then tgt = tonumber(tgt) end
                if type(tgt) == "number" and tgt > 0 and tgt ~= loserID then
                    local survivorHasCmd = type(survivorSp) == "table" and survivorSp[cmd] ~= nil
                    if not survivorHasCmd then
                        pcall(addSpecialExit, survivorID, tgt, cmd)
                    end
                end
            end
        end
    end

    -- 4. Copy user_data keys from loser to survivor (missing keys only)
    if type(getAllRoomUserData) == "function" then
        local loserData    = getAllRoomUserData(loserID)
        local survivorData = getAllRoomUserData(survivorID)
        if type(loserData) == "table" then
            for k, v in pairs(loserData) do
                if k ~= "locked" then  -- never carry lock state from loser
                    local survivorHas = type(survivorData) == "table" and survivorData[k] ~= nil
                    if not survivorHas then
                        setRoomUserData(survivorID, k, v)
                    end
                end
            end
        end
    end

    -- 5. Clear hash on loser so the binding is released before deletion
    if type(setRoomIDbyHash) == "function" then
        pcall(setRoomIDbyHash, loserID, "")
    end

    -- 6. Drop loser from posCache
    if posCache then
        local lx, ly, lz = getRoomCoordinates(loserID)
        _.pos_cache_drop(posCache, lx, ly, lz, loserID)
        -- Also remove from the _rooms list in the cache
        if type(posCache._rooms) == "table" then
            for i = #posCache._rooms, 1, -1 do
                if posCache._rooms[i] == loserID then
                    table.remove(posCache._rooms, i)
                    break
                end
            end
        end
    end

    -- 7. Delete the loser room
    pcall(deleteRoom, loserID)
end

-- De-duplicate all rooms in areaID that share the same hash.
-- Returns { groups=N, removed=M, skipped=K }.
-- posCache is optional; if provided it is kept up-to-date so the caller
-- (normalize pipeline) can reuse it for the subsequent reconcile pass.
function map.dedupe_area_by_hash(areaID, posCache)
    if type(areaID) ~= "number" or areaID < 1 then
        return { groups = 0, removed = 0, skipped = 0 }
    end
    local groups  = _.find_duplicate_hash_groups(areaID)
    local removed = 0
    local skipped = 0

    if #groups == 0 then
        return { groups = 0, removed = 0, skipped = 0 }
    end

    -- Collect all loser IDs so we can build the reverse exit index once.
    -- First pass: choose survivors.
    local survivorFor = {}  -- loserID → survivorID
    local losers      = {}  -- list of loserIDs
    for _i, group in ipairs(groups) do
        -- If ALL members are immobile we cannot touch this group.
        local allImmobile = true
        for _j, rid in ipairs(group) do
            if not _.is_room_immobile(rid) then allImmobile = false; break end
        end
        if allImmobile then
            skipped = skipped + 1
        else
            local survivor = _.choose_survivor(group)
            for _j, rid in ipairs(group) do
                if rid ~= survivor then
                    survivorFor[rid] = survivor
                    losers[#losers + 1] = rid
                end
            end
        end
    end

    if #losers == 0 then
        return { groups = #groups, removed = 0, skipped = skipped }
    end

    -- Build reverse exit index once for all losers.
    local revIndex = build_reverse_exit_index(losers)

    for _i, loserID in ipairs(losers) do
        local survivor = survivorFor[loserID]
        _.merge_duplicate_room(survivor, loserID, posCache, revIndex)
        removed = removed + 1
    end

    return { groups = #groups, removed = removed, skipped = skipped }
end

-- --------------------------------------------------------------------------
-- Anchor-based coordinate translation helpers
-- --------------------------------------------------------------------------

-- Parse a "X,Y" or "X,Y,Z" coord string (with optional spaces) into numbers.
-- Returns x, y, z (z defaults to nil if not present).
local function parse_coord_string(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")  -- trim
    local parts = {}
    for part in s:gmatch("[^,]+") do
        parts[#parts + 1] = tonumber(part:match("^%s*(.-)%s*$"))
    end
    if #parts >= 2 and parts[1] and parts[2] then
        return parts[1], parts[2], parts[3]
    end
    return nil
end

-- Returns a table { [roomID] = {x, y, z} } for every room in areaID that
-- has a valid user_data.coord string.
function _.collect_coord_anchors(areaID)
    if type(areaID) ~= "number" or areaID < 1 then return {} end
    local rooms   = getAreaRooms(areaID)
    local anchors = {}
    if type(rooms) ~= "table" then return anchors end
    for _i, rid in ipairs(rooms) do
        local coordStr = getRoomUserData(rid, "coord")
        if type(coordStr) == "string" and coordStr ~= "" then
            local ax, ay, az = parse_coord_string(coordStr)
            if ax and ay then
                anchors[rid] = { x = ax, y = ay, z = az }
            end
        end
    end
    return anchors
end

-- BFS-walk the area from seedID and collect all reachable room IDs.
-- visited (optional) lets callers share a visited set across components.
local function bfs_component(seedID, areaID, visited)
    visited = visited or {}
    if visited[seedID] then return {} end
    local component = {}
    local queue     = { seedID }
    local qHead     = 1
    visited[seedID] = true
    while qHead <= #queue do
        local cur = queue[qHead]; qHead = qHead + 1
        component[#component + 1] = cur
        local exits = getRoomExits(cur)
        if type(exits) == "table" then
            for _i, tgt in pairs(exits) do
                if type(tgt) == "string" then tgt = tonumber(tgt) end
                if type(tgt) == "number" and tgt > 0
                    and getRoomArea(tgt) == areaID
                    and not visited[tgt] then
                    visited[tgt] = true
                    queue[#queue + 1] = tgt
                end
            end
        end
    end
    return component
end

-- Translate every room in `component` by (dx, dy), skipping immobile rooms.
-- Returns true if the full translation was applied, false if any immobile
-- room would need to move (in that case NO rooms are moved).
-- posCache is updated for each move.
function _.translate_subgraph(component, dx, dy, posCache)
    if dx == 0 and dy == 0 then return true end

    -- Check that no immobile room needs to move AND preflight collision check.
    -- We allow collisions WITHIN this component (they'll move away together).
    local componentSet = {}
    for _i, rid in ipairs(component) do componentSet[rid] = true end

    for _i, rid in ipairs(component) do
        local rx, ry, rz = getRoomCoordinates(rid)
        if rx == nil then return false end  -- room has no coords, abort
        local nx, ny = rx + dx, ry + dy
        if _.is_room_immobile(rid) and (nx ~= rx or ny ~= ry) then
            return false  -- all-or-nothing: an immobile room blocks the whole translate
        end
        -- Preflight collision: is the destination occupied by a room NOT in this component?
        if posCache then
            local occupants = _.pos_cache_get(posCache, nx, ny, rz)
            if type(occupants) == "table" then
                for _j, oid in ipairs(occupants) do
                    if not componentSet[oid] then
                        return false  -- collision with outside room — abort
                    end
                end
            end
        end
    end

    -- Apply the translation
    for _i, rid in ipairs(component) do
        local rx, ry, rz = getRoomCoordinates(rid)
        if rx ~= nil then
            setRoomCoordinates(rid, rx + dx, ry + dy, rz)
            if posCache then
                _.pos_cache_move(posCache, rx, ry, rz, rx + dx, ry + dy, rz, rid)
            end
        end
    end
    return true
end

-- For each connected sub-graph in areaID:
--   - Collect anchor rooms (those with user_data.coord).
--   - Compute Δ = (coord.x − room.x, coord.y − room.y) per anchor.
--   - If all anchors agree → translate the sub-graph.
--   - If anchors disagree → pick the Δ from the lowest anchor id, count disagreement.
--   - If no anchors → count unanchored sub-graph.
-- Returns { anchor_disagreements=N, unanchored_subgraphs=N, translated=N, skipped=N }.
function _.apply_anchor_translation(areaID, posCache)
    local result = { anchor_disagreements = 0, unanchored_subgraphs = 0, translated = 0, skipped = 0 }
    if type(areaID) ~= "number" or areaID < 1 then return result end
    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" or #rooms == 0 then return result end

    local anchors  = _.collect_coord_anchors(areaID)
    local visited  = {}

    for _i, seedID in ipairs(rooms) do
        if not visited[seedID] then
            local component = bfs_component(seedID, areaID, visited)
            if #component > 0 then
                -- Find anchors in this component
                local compAnchors = {}
                for _j, rid in ipairs(component) do
                    if anchors[rid] then
                        compAnchors[#compAnchors + 1] = rid
                    end
                end

                if #compAnchors == 0 then
                    result.unanchored_subgraphs = result.unanchored_subgraphs + 1
                else
                    -- Compute Δ per anchor
                    local deltas    = {}
                    local disagreed = false
                    local refDX, refDY, refID

                    for _j, aid in ipairs(compAnchors) do
                        local ax, ay, _az = getRoomCoordinates(aid)
                        if ax then
                            local tdx = anchors[aid].x - ax
                            local tdy = anchors[aid].y - ay
                            if refDX == nil then
                                refDX, refDY, refID = tdx, tdy, aid
                            elseif tdx ~= refDX or tdy ~= refDY then
                                disagreed = true
                                -- prefer lower id
                                if aid < refID then
                                    refDX, refDY, refID = tdx, tdy, aid
                                end
                            end
                            deltas[#deltas + 1] = { dx = tdx, dy = tdy, id = aid }
                        end
                    end

                    if disagreed then
                        result.anchor_disagreements = result.anchor_disagreements + 1
                    end

                    if refDX ~= nil then
                        local ok = _.translate_subgraph(component, refDX, refDY, posCache)
                        if ok then
                            result.translated = result.translated + 1
                        else
                            result.skipped = result.skipped + 1
                        end
                    end
                end
            end
        end
    end

    return result
end

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
