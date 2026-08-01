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
    "top of a huge tree",
    "a tall wooden watchtower",
    "upper tower floor",
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
    if type(terrain) ~= "string" then return end
    local target = _.terrain_types[terrain]
    if not target then
        local lowered = string.lower(terrain)
        target = _.terrain_types[lowered]
    end
    if not target then
        local canonical = _.normalize_terrain_name(terrain)
        if canonical then
            target = _.terrain_types[canonical]
        end
    end
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
        return _.normalize_terrain_name(storedTerrain) or storedTerrain
    end

    local envID = getRoomEnv(roomID)
    if type(envID) ~= "number" then return nil end

    return _.envID_to_terrain[envID] or nil
end

-- Returns the mapper room ID of a placeholder that should be adopted for the
-- given arrival, or nil if no adoptable placeholder is found.
--
-- A "placeholder" is a room created by create_neighbors_for_current_room
-- before the player has visited it. If the room still has its placeholder
-- hash as its visible name, treat it as adoptable even when the user has
-- manually set a terrain on it.
--
-- Lookup order:
--  1. The room Mudlet already thinks is the target of prevRoomID's exit in
--     arrivalDir — most reliable, uses Mudlet's own exit table.
--  2. getRoomsByPosition at the expected adjacent coordinate — fallback for
--     cases where the exit hadn't been wired yet.
local function is_placeholder(roomID)
    local name = getRoomName(roomID) or ""
    local roomHash = type(getRoomHashByID) == "function" and getRoomHashByID(roomID) or nil
    if type(roomHash) == "string" and roomHash ~= "" and name == roomHash then
        return true
    end
    local unvisitedID = _.terrain_types["unvisited"] and _.terrain_types["unvisited"].id or 46
    if getRoomEnv(roomID) ~= unvisitedID then return false end
    -- Name is the raw hash (32 hex chars, no spaces) — as set in Layout.lua
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
-- Per-area room index (hash → ID, name → IDs)
-- --------------------------------------------------------------------------
-- Two hot-path lookups used to answer every query with a full getAreaRooms()
-- walk plus a C++ round-trip per room:
--
--   * `resolve_room_id_by_hash` called getRoomHashByID() per room, twice per
--     newly-discovered room (hint area, then the previous room's area);
--   * `find_real_room_to_adopt` Phase 2 called getRoomName() per room on the
--     same event.
--
-- Both scale linearly with area size and both fire on the movement hot path.
-- Instead we pay one walk per area and keep the result in
--
--   map._area_index[areaID] = {
--     byHash = { [hash]      = roomID    },
--     byName = { [lowerName] = { roomID, ... } },
--   }
--
-- Unlike the pos cache this survives area changes, so the build is amortised
-- over the whole session rather than re-paid on every entry — hence its own,
-- much higher size cap (index_area_threshold, see Data.lua).
--
-- Staleness is handled asymmetrically.  Bindings we make ourselves are folded
-- in through bind_room_hash / set_room_name, so the index never *misses* an
-- entry.  Cleared hashes, renames, deletes and area moves leave a stale entry
-- behind instead; every read re-verifies its candidates against Mudlet before
-- handing them back and prunes whatever no longer holds, so a stale entry can
-- never produce a wrong answer.

-- Areas at or above index_area_threshold are left unindexed: the one-off build
-- would freeze Mudlet, and the callers all degrade gracefully to "not found".
function _.is_indexable_area(areaID)
    if type(areaID) ~= "number" or areaID < 1 then return false end
    local threshold = tonumber(map.configs and map.configs.index_area_threshold) or 50000
    return _.get_estimated_area_room_count(areaID) < threshold
end

function _.build_area_index(areaID)
    local index = { byHash = {}, byName = {} }
    if type(areaID) ~= "number" or areaID < 1 then return index end
    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then return index end
    _.record_area_room_count(areaID, #rooms)
    local has_hash = type(getRoomHashByID) == "function"
    for _, rid in ipairs(rooms) do
        if has_hash then
            local h = getRoomHashByID(rid)
            if type(h) == "string" and h ~= "" then index.byHash[h] = rid end
        end
        local n = getRoomName(rid)
        if type(n) == "string" and n ~= "" then
            local key = string.lower(n)
            local list = index.byName[key]
            if list == nil then
                index.byName[key] = { rid }
            else
                list[#list + 1] = rid
            end
        end
    end
    return index
end

-- How many area indexes to keep resident.  Resolution only ever consults the
-- hint area and the previous room's area, so a handful covers every realistic
-- movement pattern; the cap just stops a long session in a big world from
-- accumulating one entry per room for every area ever visited.
local AREA_INDEX_MAX_AREAS = 8

-- Returns the (lazily built) index for areaID, or nil when the area is too
-- large to index.
function _.get_area_index(areaID)
    if not _.is_indexable_area(areaID) then return nil end
    map._area_index = map._area_index or {}
    local index = map._area_index[areaID]
    if index == nil then
        local cached = 0
        for _k in pairs(map._area_index) do cached = cached + 1 end
        if cached >= AREA_INDEX_MAX_AREAS then map._area_index = {} end
        index = _.build_area_index(areaID)
        map._area_index[areaID] = index
    end
    return index
end

-- Drop the cached index for areaID, or every area when areaID is nil.
function _.invalidate_area_index(areaID)
    if type(map._area_index) ~= "table" then return end
    if areaID == nil then
        map._area_index = {}
    else
        map._area_index[areaID] = nil
    end
end

-- Resolve the area an index update applies to.  `areaID` is passed explicitly
-- by callers that touch a room before setRoomArea has run (newly created rooms
-- are hashed and named first).  Returns nil when the area has no live index,
-- in which case the update is a no-op — the next build reads the truth from
-- Mudlet anyway.
local function live_index_for(roomID, areaID)
    if type(map._area_index) ~= "table" then return nil end
    if type(roomID) ~= "number" or roomID < 1 then return nil end
    if type(areaID) ~= "number" or areaID < 1 then areaID = getRoomArea(roomID) end
    if type(areaID) ~= "number" or areaID < 1 then return nil end
    return map._area_index[areaID]
end

function _.note_room_hash(roomID, hash, areaID)
    if type(hash) ~= "string" or hash == "" then return end
    local index = live_index_for(roomID, areaID)
    if index then index.byHash[hash] = roomID end
end

function _.note_room_name(roomID, name, areaID)
    if type(name) ~= "string" or name == "" then return end
    local index = live_index_for(roomID, areaID)
    if index == nil then return end
    local key = string.lower(name)
    local list = index.byName[key]
    if list == nil then
        index.byName[key] = { roomID }
        return
    end
    for i = 1, #list do if list[i] == roomID then return end end
    list[#list + 1] = roomID
    -- The room's previous name still lists it; that entry is pruned on read.
end

-- setRoomIDbyHash + index bookkeeping.  Use this for every *binding* call;
-- clearing calls (`setRoomIDbyHash(id, "")`) need no wrapper because a cleared
-- hash is caught by the read-side verification.
function _.bind_room_hash(roomID, hash, areaID)
    setRoomIDbyHash(roomID, hash)
    _.note_room_hash(roomID, hash, areaID)
end

-- setRoomName + index bookkeeping.
function _.set_room_name(roomID, name, areaID)
    setRoomName(roomID, name)
    _.note_room_name(roomID, name, areaID)
end

-- Rooms in areaID whose name lower-cases to `nameLower`, each verified against
-- Mudlet so a stale entry can never hand back the wrong room.  Returns nil when
-- the area is not indexable (callers treat that as "no answer available"), or
-- an empty table when the area genuinely holds no such room.
function _.rooms_with_name(areaID, nameLower)
    local index = _.get_area_index(areaID)
    if index == nil then return nil end
    local ids = index.byName[nameLower]
    if ids == nil then return {} end
    local live = {}
    for _, rid in ipairs(ids) do
        local n = getRoomName(rid)
        if type(n) == "string" and string.lower(n) == nameLower
            and getRoomArea(rid) == areaID then
            live[#live + 1] = rid
        end
    end
    if #live ~= #ids then
        index.byName[nameLower] = (#live > 0) and live or nil
    end
    return live
end

-- --------------------------------------------------------------------------
-- Self-healing hash lookup
-- --------------------------------------------------------------------------
-- Mudlet keeps two mappings for room hashes: forward (getRoomHashByID, stored
-- on the room) and reverse (getRoomIDbyHash, an index).  These can drift out
-- of sync — a room still stores its hash, but the reverse index returns -1.
-- When that happens, handle_move / create_neighbors treat the room as MISSING
-- and fall into "adopt or create", which spawns placeholder stubs and stacked
-- duplicates (the fan-out you see in the JSON dumps).
--
-- This helper repairs the desync in place: on a reverse-index miss it scans a
-- bounded set of rooms for one whose stored hash matches `vnum`, re-binds the
-- reverse index, and returns the real room ID — so no placeholder is created.
--
--   vnum     : the GMCP room hash we are trying to resolve.
--   areaHint : optional area ID to scan first (keeps the cost bounded).
-- Returns a valid room ID, or -1 when no matching room exists.
function _.resolve_room_id_by_hash(vnum, areaHint)
    if type(vnum) ~= "string" or vnum == "" then return -1 end

    -- Fast path: reverse index is intact and points at a live room.
    local id = getRoomIDbyHash(vnum)
    if type(id) == "number" and id > 0 then
        local a = getRoomArea(id)
        if type(a) == "number" and a > 0 then
            return id
        end
    end

    if type(getRoomHashByID) ~= "function" then return -1 end

    -- Slow path: consult the per-area index for a room whose stored hash
    -- matches vnum.  It costs one getAreaRooms() walk the first time an area is
    -- queried and is O(1) thereafter; areas too big to index (and hence to
    -- scan, which is what this used to do) simply report no match.
    local function scan(areaID)
        if type(areaID) ~= "number" or areaID < 1 then return nil end

        -- A hit is only trusted once Mudlet confirms the room still stores the
        -- hash and still lives in this area; anything else means the index went
        -- stale (hash cleared, room deleted, room moved) so we rebuild once and
        -- retry.  A verified miss is trusted directly — a binding made through
        -- Mudlet's API would have been answered by the fast path above.
        local function lookup(index)
            if index == nil then return nil end
            local rid = index.byHash[vnum]
            if type(rid) ~= "number" or rid < 1 then return nil, false end
            if getRoomHashByID(rid) == vnum and getRoomArea(rid) == areaID then
                return rid, false
            end
            index.byHash[vnum] = nil
            return nil, true
        end

        local found, stale = lookup(_.get_area_index(areaID))
        if found == nil and stale then
            _.invalidate_area_index(areaID)
            found = lookup(_.get_area_index(areaID))
        end
        return found
    end

    local found = scan(areaHint)

    -- Fall back to the previous room's area (we almost always move within it).
    if not found and type(map.prev_info) == "table"
        and type(map.prev_info.vnum) == "string" then
        local prevID = getRoomIDbyHash(map.prev_info.vnum)
        if type(prevID) == "number" and prevID > 0 then
            local prevArea = getRoomArea(prevID)
            if prevArea ~= areaHint then
                found = scan(prevArea)
            end
        end
    end

    if type(found) == "number" and found > 0 then
        pcall(setRoomIDbyHash, found, vnum)
        if type(_.mark_autowalk_dirty) == "function" then _.mark_autowalk_dirty() end
        if type(_.debug_echo) == "function" then
            _.debug_echo("Repaired stale hash index: re-bound vnum " .. vnum
                .. " to existing room " .. found .. "\n")
        end
        return found
    end

    return -1
end

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

    -- Phase 2: name + exit-set match across the area.  The name lookup comes
    -- from the per-area index rather than a getAreaRooms() walk with a
    -- getRoomName() per room, so the cost is proportional to how many rooms
    -- share this name (nearly always a handful) instead of to the area size.
    -- nil means the area is too big to index: report no match rather than
    -- freezing Mudlet on every step into unmapped territory.
    local nameLower  = string.lower(info.name)
    local candidates = _.rooms_with_name(areaID, nameLower)
    if candidates == nil then return nil end
    local bestID, bestScore, tied = nil, 1, false
    for _, rid in ipairs(candidates) do
        if is_adoptable(rid) then
            local s = score_exit_match(rid, info)
            if s > bestScore then
                bestID, bestScore, tied = rid, s, false
            elseif s == bestScore and bestID ~= nil then
                tied = true
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
    value = string.lower(value)
    local canonical = _.terrain_canonical_names and _.terrain_canonical_names[value] or nil
    return canonical or value
end

function _.current_room_uses_grid_mode()
    if map.room_info == nil then return false end
    if _.is_elevated_room_name(map.room_info.name) then return false end
    return map.room_info.terrain ~= nil
end

-- Returns the "canonical" z-level for roomID based on its terrain, or nil if
-- the terrain is not in _.forced_z_by_terrain_name.
--
-- USAGE CONSTRAINT: call this only from whole-component normalisation passes
-- (normalize_room_layout, recalculate_room_layout).  Do NOT use it to place
-- individual neighbours during movement — a horizontal exit neighbour must
-- share the current room's z-plane (cz), regardless of terrain.
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

-- --------------------------------------------------------------------------
-- Large-area helpers
-- --------------------------------------------------------------------------
-- Lightweight room-count cache.  Rather than calling getAreaRooms() every time
-- we need to know whether an area is "large", we cache the count the first
-- time it is queried and keep it updated incrementally as rooms are added.
-- The cache lives in map._area_room_counts (a table keyed by areaID).

function _.get_estimated_area_room_count(areaID)
    if type(areaID) ~= "number" or areaID < 1 then return 0 end
    map._area_room_counts = map._area_room_counts or {}
    local cached = map._area_room_counts[areaID]
    if type(cached) == "number" then return cached end
    -- One-time cost: count via getAreaRooms and cache the result.
    local rooms = getAreaRooms(areaID)
    local count = type(rooms) == "table" and #rooms or 0
    map._area_room_counts[areaID] = count
    return count
end

-- Increment (or decrement with a negative delta) the cached room count for
-- areaID.  Call this whenever a room is added or deleted in areaID so the
-- estimate stays accurate without repeated getAreaRooms() calls.
function _.adjust_area_room_count(areaID, delta)
    if type(areaID) ~= "number" or areaID < 1 then return end
    map._area_room_counts = map._area_room_counts or {}
    local c = map._area_room_counts[areaID]
    if type(c) == "number" then
        map._area_room_counts[areaID] = math.max(0, c + (delta or 1))
    end
    -- If the count was never cached, leave it unknown so the next query
    -- does a fresh getAreaRooms() rather than returning a wrong estimate.
end

-- Discard the cached count for areaID (e.g. after bulk dedupe).
function _.invalidate_area_room_count(areaID)
    if type(map._area_room_counts) == "table" then
        map._area_room_counts[areaID] = nil
    end
end

-- Record an exact count observed from a getAreaRooms() walk.  Callers that
-- already paid for the walk correct the estimate here for free, which is what
-- heals any drift introduced outside the wrappers below.
function _.record_area_room_count(areaID, count)
    if type(areaID) ~= "number" or areaID < 1 then return end
    if type(count) ~= "number" then return end
    map._area_room_counts = map._area_room_counts or {}
    map._area_room_counts[areaID] = count
end

-- --------------------------------------------------------------------------
-- Room lifecycle wrappers
-- --------------------------------------------------------------------------
-- The room-count estimate above is only as good as the events fed into it.  It
-- used to see +1 on creation and nothing else: no decrement on any of the six
-- deleteRoom sites, and no transfer when setRoomArea moved a room between
-- areas.  The estimate therefore drifted upward for as long as a session ran,
-- and since it decides is_large_area / is_indexable_area, a mid-size area could
-- latch as "large" after enough dedup churn and silently lose its pos cache,
-- its stretch pass, its hash repair and Phase 2 adoption.
--
-- Routing both mutations through these wrappers makes the count exact with
-- respect to everything this script does.  Anything that edits the map behind
-- our back (Mudlet's own mapper, a map file reload) is covered by the reset on
-- sysConnectionEvent and by record_area_room_count above.

-- addRoom + room-count bookkeeping.  Mudlet versions differ on whether a fresh
-- room starts with no area or lands in the default one, so we count it into
-- whatever getRoomArea reports: an invalid area no-ops here and the room is
-- counted by the set_room_area below instead, while a real default area is
-- counted here and set_room_area's early-out keeps it from counting twice.
function _.add_room(roomID)
    addRoom(roomID)
    _.adjust_area_room_count(getRoomArea(roomID), 1)
end

-- setRoomArea + room-count bookkeeping: a move debits the old area and credits
-- the new one, and assigning an area to a room that had none credits only.
function _.set_room_area(roomID, areaID)
    if type(roomID) ~= "number" or roomID < 1 then return end
    local oldArea = getRoomArea(roomID)
    setRoomArea(roomID, areaID)
    if oldArea == areaID then return end
    if type(oldArea) == "number" and oldArea > 0 then
        _.adjust_area_room_count(oldArea, -1)
    end
    if type(areaID) == "number" and areaID > 0 then
        _.adjust_area_room_count(areaID, 1)
    end
    -- Position-cache bookkeeping: the room keeps its coordinates but changes
    -- which area's cache owns them, so it has to stop occupying its cell in the
    -- old area's cache and start occupying it in the new one.
    local x, y, z = getRoomCoordinates(roomID)
    if x ~= nil then
        local from = _.live_pos_cache(oldArea)
        if from then _.pos_cache_remove(from, x, y, z, roomID) end
        local to = _.live_pos_cache(areaID)
        if to then _.pos_cache_add(to, x, y, z, roomID) end
    end
end

-- deleteRoom + room-count bookkeeping.  The area and coordinates have to be
-- read before the room goes away.  Returns true when Mudlet accepted the
-- delete, so callers can keep their own tallies and cache drops in step with
-- what actually happened.
function _.delete_room(roomID)
    if type(roomID) ~= "number" or roomID < 1 then return false end
    if type(deleteRoom) ~= "function" then return false end
    local areaID = getRoomArea(roomID)
    local x, y, z = getRoomCoordinates(roomID)
    local ok = pcall(deleteRoom, roomID)
    if ok and type(areaID) == "number" and areaID > 0 then
        _.adjust_area_room_count(areaID, -1)
        -- Drop it from the long-lived cache here so no delete site can leave a
        -- phantom occupant behind in it; callers still drop from their own.
        local live = _.live_pos_cache(areaID)
        if live and x ~= nil then _.pos_cache_remove(live, x, y, z, roomID) end
    end
    return ok
end

-- Returns true when the area exceeds the configured large_area_threshold.
function _.is_large_area(areaID)
    local threshold = tonumber(map.configs and map.configs.large_area_threshold) or 5000
    return _.get_estimated_area_room_count(areaID) >= threshold
end

-- Compute a sensible default move cap for the deep reconcile BFS.
--
-- The reconcile in Layout.lua bails out of its BFS as soon as it has
-- repositioned `maxMoves` rooms (`if moved >= maxMoves then return moved end`).
-- On very large areas the static default (reconcile_deep_max_moves, ~5000) is
-- hit almost immediately, so the vast majority of rooms are never repositioned
-- and show up in the audit as "delta mismatches remaining".
--
-- To let a large area actually finish normalising we scale the cap with the
-- area size: every room may be moved at most once per pass, so roomCount *
-- maxPasses is an upper bound on the useful work.  Convergence normally stops
-- far earlier (each pass breaks when it makes zero moves), and maxPasses still
-- bounds the number of passes, so this only removes the premature mid-pass
-- bail-out — it does not make a converging area loop forever.
--
-- The user can still override the cap explicitly (e.g. "map normalize 200"),
-- in which case callers should pass their value through unchanged.
function _.scaled_reconcile_move_cap(roomCount, maxPasses, baseCap)
    baseCap   = tonumber(baseCap) or 5000
    roomCount = tonumber(roomCount) or 0
    maxPasses = tonumber(maxPasses) or 1
    if roomCount < 1 or maxPasses < 1 then return baseCap end
    local scaled = roomCount * maxPasses
    if scaled > baseCap then return scaled end
    return baseCap
end

function _.should_skip_stretch_for_area(areaID)
    -- Always skip stretch for large areas: iterating millions of rooms to
    -- shift coordinates would freeze Mudlet for a long time.
    if _.is_large_area(areaID) then return true end
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
    _.record_area_room_count(areaID, #rooms)
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

-- True when `cache` is the cache for areaID, so a mutation in that area has to
-- be mirrored into it.  Large-area sentinels match too: they hold no full coord
-- map, but recording the cells we touch is what lets the per-event dedup
-- backstop in create_neighbors_for_current_room work on a large area.
function _.pos_cache_matches_area(cache, areaID)
    return type(cache) == "table" and cache._areaID == areaID
end

-- True when a nil look-up in `cache` can be trusted to mean "that cell is
-- empty" rather than "this cache has no coordinate data for the area".
function _.pos_cache_is_authoritative(cache, areaID)
    return _.pos_cache_matches_area(cache, areaID) and not cache._large_area
end

-- The long-lived cache Core.lua keeps for the player's current area across GMCP
-- events, when it describes areaID.  Mutations reach this cache through the
-- lifecycle wrappers rather than through call sites, so paths that never see it
-- (map normalize, map recalculate, make_room's stretch, area merges) cannot
-- leave it stale.
function _.live_pos_cache(areaID)
    if _.pos_cache_matches_area(map._pos_cache, areaID) then return map._pos_cache end
    return nil
end

-- Occupancy of one cell: answered from the cache when the cache can answer,
-- and from Mudlet otherwise.  Returns a non-empty array of roomIDs, or nil when
-- the cell is empty.
--
-- Call sites used to spell this `pos_cache_get(...) or getRoomsByPosition(...)`,
-- which cannot tell "empty cell" from "no data" — pos_cache_get returns nil for
-- both.  While exploring, most probed cells are empty, so that fallback fired
-- on nearly every exit of every step and each firing is an O(area) scan inside
-- Mudlet: the cache was built and then bypassed.  The large-area sentinel is
-- what actually means "no data", so key the fallback off that and let a real
-- cache answer negatives itself.
function _.rooms_at_position(cache, areaID, x, y, z)
    if x == nil or y == nil or z == nil then return nil end
    if _.pos_cache_is_authoritative(cache, areaID) then
        return cache[pc_key(x, y, z)]
    end
    if type(getRoomsByPosition) ~= "function" then return nil end
    local hits = getRoomsByPosition(areaID, x, y, z)
    if type(hits) ~= "table" or next(hits) == nil then return nil end
    return hits
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

-- Drop a room from the cache entirely (used after deleteRoom).  Caller must
-- pass the room's last-known coords — we cannot look them up post-delete.
function _.pos_cache_drop(cache, x, y, z, id)
    if cache == nil then return end
    if x ~= nil and id ~= nil then _.pos_cache_remove(cache, x, y, z, id) end
end

-- setRoomCoordinates + position-cache bookkeeping.
--
-- Every coordinate write has to be mirrored into every cache that describes the
-- room's area, because a nil look-up is now authoritative for "empty cell"
-- (see rooms_at_position).  An unmirrored move makes a cache claim both that
-- the room is still on its old cell and that its new cell is free, and the
-- second half of that is how rooms end up stacked.
--
-- posCache is the caller's own cache, if it has one; the long-lived Core cache
-- is looked up here so callers that never receive it still cannot leave it
-- stale.  Coordinates are passed straight through to Mudlet, but only a fully
-- coordinated position is mirrored: pos_cache keys are built by concatenation,
-- so a nil component would raise inside pc_key.
local function mirror_move(cache, id, ox, oy, oz, x, y, z)
    if ox ~= nil and oy ~= nil and oz ~= nil then
        _.pos_cache_remove(cache, ox, oy, oz, id)
    end
    if x ~= nil and y ~= nil and z ~= nil then
        _.pos_cache_add(cache, x, y, z, id)
    end
end

function _.set_room_coordinates(roomID, x, y, z, posCache)
    if type(roomID) ~= "number" or roomID < 1 then return end
    local areaID     = getRoomArea(roomID)
    local ox, oy, oz = getRoomCoordinates(roomID)
    setRoomCoordinates(roomID, x, y, z)

    if _.pos_cache_matches_area(posCache, areaID) then
        mirror_move(posCache, roomID, ox, oy, oz, x, y, z)
    end
    local live = _.live_pos_cache(areaID)
    if live ~= nil and live ~= posCache then
        mirror_move(live, roomID, ox, oy, oz, x, y, z)
    end
end

-- Find the nearest unoccupied cell to (x,y,z) on the same z-plane, searched in
-- expanding Chebyshev rings out to maxRadius.  "Unoccupied" is judged from the
-- supplied position cache, so callers must keep the cache current (relocate
-- rooms via set_room_coordinates).  Returns nx,ny,nz or nil if the whole search
-- radius is full.
-- Only the perimeter of each ring is a candidate — the interior belongs to a
-- ring already searched — so walk the perimeter directly instead of scanning the
-- full (2r+1)² square and discarding the interior.  That is O(r) per ring and
-- O(maxRadius²) overall, rather than O(r²) per ring and O(maxRadius³) overall:
-- at the default maxRadius of 64 an exhausted search costs ~12.5k loop
-- iterations instead of ~366k for the same ~16.6k cell look-ups.  Probe order is
-- unchanged from the square-scan version (west column south-to-north, then each
-- intermediate column's two ends, then the east column), so the cell chosen for
-- a given cache is identical.
function _.find_free_cell_near(cache, x, y, z, maxRadius)
    if cache == nil or x == nil then return nil end
    maxRadius = tonumber(maxRadius) or 64
    for r = 1, maxRadius do
        -- West column, in full.
        for dy = -r, r do
            local nx, ny = x - r, y + dy
            if _.pos_cache_get(cache, nx, ny, z) == nil then return nx, ny, z end
        end
        -- Intermediate columns: south and north ends only.
        for dx = -r + 1, r - 1 do
            local nx = x + dx
            if _.pos_cache_get(cache, nx, y - r, z) == nil then return nx, y - r, z end
            if _.pos_cache_get(cache, nx, y + r, z) == nil then return nx, y + r, z end
        end
        -- East column, in full.
        for dy = -r, r do
            local nx, ny = x + r, y + dy
            if _.pos_cache_get(cache, nx, ny, z) == nil then return nx, ny, z end
        end
    end
    return nil
end

-- How well a room agrees with its neighbours: the number of its exits whose
-- target already sits at exactly the coordinate delta the exit implies.  A
-- higher score means the room is better placed within its cluster.
--
-- (x, y, z) is the position to score the room *at*; pass nil to score it where
-- it currently sits.  Scoring a hypothetical position is what lets a caller ask
-- "would this room be better anchored here than the room already here?" before
-- moving anything.
--
-- Note the asymmetry with the exits pointing *at* rid: those belong to the
-- neighbours and are not counted.  A room with no exits of its own therefore
-- always scores 0, which is what makes unvisited placeholders lose every
-- contest for a cell.
function _.exit_consistency_score(rid, x, y, z)
    if type(rid) ~= "number" or rid < 1 then return 0 end
    local exits = getRoomExits(rid)
    if type(exits) ~= "table" then return 0 end
    if x == nil then
        x, y, z = getRoomCoordinates(rid)
        if x == nil then return 0 end
    end
    local score = 0
    for dir, tgt in pairs(exits) do
        if type(tgt) == "string" then tgt = tonumber(tgt) end
        if type(tgt) == "number" and tgt > 0 and tgt ~= rid then
            local shift = _.get_shift_for_exit_key(dir)
            if shift then
                local tx, ty, tz = getRoomCoordinates(tgt)
                if tx ~= nil and (tx - x) == shift[1]
                    and (ty - y) == shift[2] and (tz - z) == shift[3] then
                    score = score + 1
                end
            end
        end
    end
    return score
end

-- Separate genuinely-distinct rooms that ended up sharing the same map cell.
--
-- The reconcile/anchor passes embed the room graph into a 3-D grid by walking
-- exits from a seed; they give no global guarantee that two rooms in different
-- sub-graphs (or a stale, un-normalised cluster) never land on the same cell.
-- dedupe_area_by_hash only merges *same-hash* duplicates, so two real rooms
-- with different hashes can still overlap after normalise (they hide each other
-- on the map).
--
-- This pass keeps the best-anchored occupant of each shared cell and nudges the
-- other occupants to the nearest free cell on the same z-plane.  It is a
-- last-resort visual fix: a nudged room may gain new delta mismatches with its
-- own neighbours, but the overlap is removed.
--
-- anchorRoomID: the room the calling pass started from, if any — always
--   immovable. respectRealLocks: when true, rooms with the "locked" flag (and
--   the player's current room) are ALSO immovable; single-room normalize /
--   recalculate pass false here (only the anchor is pinned — see
--   with_single_locked_anchor), while bulk passes with no single anchor
--   (map normalize all / normalize_all_areas) pass true to keep respecting
--   locks as they always have.
--
-- Returns { separated = N, unresolved = M }.
--   separated  — rooms moved off a shared cell onto a free one
--   unresolved — rooms left overlapping (no free cell within maxRadius, or all
--                occupants were immobile)
function _.resolve_room_overlaps(areaID, posCache, maxRadius, anchorRoomID, respectRealLocks)
    local result = { separated = 0, unresolved = 0 }
    if type(areaID) ~= "number" or areaID < 1 then return result end
    maxRadius = tonumber(maxRadius) or 64

    local cache = posCache
    if type(cache) ~= "table" or cache._areaID ~= areaID then
        cache = _.build_pos_cache(areaID)
    end

    local function immobile(rid)
        if anchorRoomID ~= nil and rid == anchorRoomID then return true end
        if not respectRealLocks then return false end
        if type(rid) == "number" and rid > 0 and getRoomUserData(rid, "locked") == "1" then
            return true
        end
        return type(_.current_player_room_id) == "function" and rid == _.current_player_room_id()
    end

    -- The occupant that keeps a shared cell is the one that agrees with most of
    -- its own neighbours where it stands.
    local consistency_score = _.exit_consistency_score

    -- Pick the occupant that keeps the cell: the anchor first, then the most
    -- exit-consistent, then lowest id.
    local function pick_keeper(ids)
        local best      = ids[1]
        local bestAnchor = immobile(best)
        local bestScore  = consistency_score(best)
        for i = 2, #ids do
            local rid    = ids[i]
            local anchor = immobile(rid)
            local score  = consistency_score(rid)
            local better
            if anchor ~= bestAnchor then
                better = anchor
            elseif score ~= bestScore then
                better = score > bestScore
            else
                better = rid < best
            end
            if better then
                best, bestAnchor, bestScore = rid, anchor, score
            end
        end
        return best
    end

    -- Nearest free cell on the same z-plane, searched in expanding rings.
    local function find_free_cell(x, y, z)
        return _.find_free_cell_near(cache, x, y, z, maxRadius)
    end

    -- Snapshot the colliding cell keys first: the cache is mutated below, so we
    -- must not iterate it live.
    local collisions = {}
    for k, list in pairs(cache) do
        if type(k) == "string" and k:sub(1, 1) ~= "_"
            and type(list) == "table" and #list > 1 then
            collisions[#collisions + 1] = k
        end
    end

    for _c = 1, #collisions do
        local list = cache[collisions[_c]]
        if type(list) == "table" and #list > 1 then
            local ids = {}
            for i = 1, #list do ids[i] = list[i] end
            local keeper = pick_keeper(ids)
            for i = 1, #ids do
                local rid = ids[i]
                if rid ~= keeper then
                    local x, y, z = getRoomCoordinates(rid)
                    if immobile(rid) or x == nil then
                        result.unresolved = result.unresolved + 1
                    else
                        local fx, fy, fz = find_free_cell(x, y, z)
                        if fx == nil then
                            result.unresolved = result.unresolved + 1
                        else
                            _.set_room_coordinates(rid, fx, fy, fz, cache)
                            result.separated = result.separated + 1
                        end
                    end
                end
            end
        end
    end

    return result
end

-- --------------------------------------------------------------------------
-- Room lock (pinning manually-placed rooms)
-- --------------------------------------------------------------------------
-- A "locked" room has a user-data flag set to "1".  Normal per-move layout
-- logic (stretch, per-step reconcile) refuses to move or delete locked rooms.
-- `map normalize` and `map recalculate` are the exception: for the duration
-- of the run they treat only the room the process started from as pinned, so
-- the repair BFS can propagate fixes outward without being blocked by old
-- pins elsewhere in the area (see with_single_locked_anchor in Layout.lua).
-- This still lets `map shift`, `map lock`, and external manual placement
-- persist across normal (non-normalize/recalculate) room updates.

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
    local overlap = _.rooms_at_position(posCache, areaID, coords[1], coords[2], coords[3])
    if overlap == nil then return end
    local rooms = (posCache and posCache._rooms) or getAreaRooms(areaID)
    local rcoords
    for i, id in ipairs(rooms) do
        if not _.is_room_immobile(id) then
            rcoords = { getRoomCoordinates(id) }
            -- Nothing to shift for a room with no coordinates — and the check
            -- has to come before the arithmetic below, not after it.  posCache
            -- ._rooms is a snapshot, so it can still name a room that was
            -- deleted (or never placed) since the cache was built.
            if rcoords[1] ~= nil then
                local moved = false
                for n = 1, 3 do
                    if shift[n] ~= 0 and (rcoords[n] - coords[n]) * shift[n] <= 0 then
                        rcoords[n] = rcoords[n] - shift[n]
                        moved = true
                    end
                end
                if moved then
                    _.set_room_coordinates(id, rcoords[1], rcoords[2], rcoords[3], posCache)
                end
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
            _.set_room_area(roomID, areaID)
        end
        return
    end
    if not skipStretch then
        local overlap = _.rooms_at_position(posCache, areaID, coords[1], coords[2], coords[3])
        if overlap ~= nil then
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
    if currentArea ~= areaID then _.set_room_area(roomID, areaID) end
    local ox, oy, oz = getRoomCoordinates(roomID)
    if ox ~= coords[1] or oy ~= coords[2] or oz ~= coords[3] then
        _.set_room_coordinates(roomID, coords[1], coords[2], coords[3], posCache)
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

-- Snap vertical room pairs so that a room with an `up`/`down` exit to another
-- in-area room ends up exactly one z-level away from it.
--
-- For each in-area room G with an `up` exit to U where U is also in the area:
--   - If multiple in-area rooms share the same `up` target hash, that violates
--     the global hash-uniqueness rule → counted as shared_target_bug, not moved.
--   - If U is locked or the target cell (ux,uy,gz+1) is occupied, normalize
--     first tries to resolve the overlap:
--       * same room identifier (hash)     → merge duplicates
--       * one has terrain, one does not   → keep the terrain room
--     If the occupant still cannot be merged, it is nudged to the nearest free
--     cell so the pair can still snap; only immobile occupants (locked / player
--     room) or a completely full neighbourhood leave the snap blocked.
--   - Otherwise U's z is set to gz+1, keeping U's own (x,y).  An up/down exit
--     is not required to lead to a room directly above/below on the map — only
--     the z-level is corrected here; x/y are left alone so a target that is
--     already correctly placed by its own horizontal exits is never dragged
--     out of position to match a ground room that may itself be mid-repair.
-- Mirror logic applies for `down` exits (U's z set to gz-1).
-- Cross-area exits are ignored entirely.
--
-- Returns { snapped=N, blocked=N, shared_target_bug=N }.
--
-- externalPosCache: optional cache for areaID.  Every move and merge below is
-- mirrored into it, so a caller running several layout passes over one area can
-- build the cache once and thread it through instead of paying an O(area)
-- coordinate walk per pass.  Callers that maintain no cache of their own (e.g.
-- map recalculate, which tracks occupancy in its own BFS table) pass nothing.
function _.snap_vertical_pair(areaID, externalPosCache)
    if type(areaID) ~= "number" or areaID < 1 then
        return { snapped = 0, blocked = 0, shared_target_bug = 0 }
    end
    local areaRooms = getAreaRooms(areaID)
    if type(areaRooms) ~= "table" then
        return { snapped = 0, blocked = 0, shared_target_bug = 0 }
    end

    -- Position cache for fast occupancy lookups.
    local posCache = (type(externalPosCache) == "table" and externalPosCache._areaID == areaID)
        and externalPosCache
        or _.build_pos_cache(areaID)

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

    local function room_identifier(rid)
        if type(getRoomHashByID) ~= "function" then return nil end
        local hash = getRoomHashByID(rid)
        if type(hash) ~= "string" or hash == "" then return nil end
        return hash
    end

    local function room_has_terrain(rid)
        local terrain = _.get_room_terrain_name and _.get_room_terrain_name(rid) or nil
        return type(terrain) == "string" and terrain ~= ""
    end

    -- Reverse exit index shared by every merge this call performs.  It is a
    -- whole-world walk, so it is built at most once and only when an overlap
    -- actually needs merging — most calls resolve nothing and must not pay for
    -- it.  merge_duplicate_room keeps it current as it rewires exits, which
    -- matters here because resolve_overlap chains: the survivor of one merge
    -- can be the loser of the next.  Every candidate loser is an in-area room
    -- (resolve_overlap rejects out-of-area occupants), so areaRooms is the
    -- complete target set.
    local sharedRevIndex = nil
    local function rev_index()
        if sharedRevIndex == nil then
            sharedRevIndex = _.build_reverse_exit_index(areaRooms)
        end
        return sharedRevIndex
    end

    local function resolve_overlap(targetID, occupantID)
        if type(targetID) ~= "number" or targetID < 1 then return nil, targetID end
        if type(occupantID) ~= "number" or occupantID < 1 then return nil, targetID end
        if targetID == occupantID then return "resolved", targetID end
        if getRoomArea(occupantID) ~= areaID then return nil, targetID end

        local targetHash = room_identifier(targetID)
        local occupHash  = room_identifier(occupantID)
        local sameHash   = targetHash ~= nil and occupHash ~= nil and targetHash == occupHash
        local targetTerr = room_has_terrain(targetID)
        local occupTerr  = room_has_terrain(occupantID)

        local survivor, loser
        if sameHash then
            -- Merge same-identifier rooms. Prefer terrain-bearing room, then lower ID.
            if targetTerr ~= occupTerr then
                survivor = targetTerr and targetID or occupantID
            else
                survivor = targetID < occupantID and targetID or occupantID
            end
            loser = survivor == targetID and occupantID or targetID
        elseif targetTerr ~= occupTerr then
            -- Keep the room with terrain metadata.
            survivor = targetTerr and targetID or occupantID
            loser = survivor == targetID and occupantID or targetID
        else
            return nil, targetID
        end

        if _.is_room_immobile(loser) then
            return nil, targetID
        end

        _.merge_duplicate_room(survivor, loser, posCache, rev_index())
        return "resolved", survivor
    end

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

        local cx, cy, cz = getRoomCoordinates(targetID)
        if cx == nil then return end

        -- Only the z-level is forced to line up with the ground room; the
        -- target keeps its own (x,y) rather than being pulled onto ground's
        -- column.
        local wantZ = gz + dz
        if cz == wantZ then return end -- already correct

        -- Check target cell occupancy.
        local occupants = _.pos_cache_get(posCache, cx, cy, wantZ)
        if type(occupants) == "table" then
            -- Snapshot the occupant list: the cache mutates as we merge/relocate.
            local occ = {}
            for _i, oid in ipairs(occupants) do occ[#occ + 1] = oid end
            for _i, oid in ipairs(occ) do
                if oid ~= targetID and getRoomArea(oid) == areaID then
                    local resolved
                    resolved, targetID = resolve_overlap(targetID, oid)
                    if not resolved then
                        -- Couldn't merge the two rooms.  Rather than abandon the
                        -- snap, nudge the blocking occupant to the nearest free
                        -- cell so the vertical pair can still line up.  Only give
                        -- up (count blocked) when the occupant is immobile or the
                        -- neighbourhood is completely full.
                        if _.is_room_immobile(oid) then
                            blocked = blocked + 1
                            return
                        end
                        local ox, oy, oz = getRoomCoordinates(oid)
                        local fx, fy, fz = _.find_free_cell_near(posCache, ox, oy, oz, 64)
                        if fx == nil then
                            blocked = blocked + 1
                            return
                        end
                        _.set_room_coordinates(oid, fx, fy, fz, posCache)
                    end
                end
            end
            -- Merging can replace targetID with the occupant that is already
            -- sitting in the wanted cell.
            cx, cy, cz = getRoomCoordinates(targetID)
            if cz == wantZ then
                snapped = snapped + 1
                return
            end
        end

        _.set_room_coordinates(targetID, cx, cy, wantZ, posCache)
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
--   overlapping_rooms — distinct rooms occupying the same (x,y,z) cell (visual overlap)
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
        overlapping_rooms  = 0,
        unreachable        = 0,
    }
    if type(roomIDs) ~= "table" or #roomIDs == 0 then return counts end

    -- Build a set of all roomIDs in scope for quick lookup.
    local inScope = {}
    for _i, rid in ipairs(roomIDs) do inScope[rid] = true end

    -- Every exit target's area and coordinates are read once while tallying and
    -- again while classifying, and a room that is the target of several exits is
    -- read once per exit.  Memoise both client calls; `false` stands in for a nil
    -- answer so an unknown room is not re-queried.
    local areaOf = {}
    local function area_of(rid)
        local a = areaOf[rid]
        if a == nil then
            a = getRoomArea(rid)
            if a == nil then a = false end
            areaOf[rid] = a
        end
        if a == false then return nil end
        return a
    end

    local coordX, coordY, coordZ = {}, {}, {}
    local function coords_of(rid)
        local x = coordX[rid]
        if x == nil then
            local rx, ry, rz = getRoomCoordinates(rid)
            if rx == nil then
                coordX[rid] = false
                return nil
            end
            coordX[rid], coordY[rid], coordZ[rid] = rx, ry, rz
            return rx, ry, rz
        end
        if x == false then return nil end
        return x, coordY[rid], coordZ[rid]
    end

    -- Single exits pass.  The classification loop below needs every one of these
    -- tables complete before it can judge any room, so the exit tables are kept
    -- and re-walked instead of asking the client for them a second and third
    -- time.  Collected here:
    --   exitsOf     — each room's exit table, indexed to match roomIDs
    --   targetCount — "dir→targetID" → in-scope sources exiting that way (shared-target bug)
    --   hasIncoming — in-scope rooms that some in-scope room exits to (unreachable)
    --   duplicate hash bindings
    local exitsOf     = {}
    local targetCount = {}
    local hasIncoming = {}
    local canHash     = type(getRoomHashByID) == "function"
    local hashSeen    = {}
    for i, rid in ipairs(roomIDs) do
        local exits = getRoomExits(rid)
        if type(exits) == "table" then
            exitsOf[i] = exits
            for dir, targetID in pairs(exits) do
                if type(targetID) == "string" then targetID = tonumber(targetID) end
                if type(targetID) == "number" then
                    if inScope[targetID] then hasIncoming[targetID] = true end
                    if targetID > 0 and targetID ~= rid
                        and (not areaID or area_of(targetID) == areaID) then
                        local k = tostring(dir) .. "→" .. tostring(targetID)
                        targetCount[k] = (targetCount[k] or 0) + 1
                    end
                end
            end
        end
        if canHash then
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

    -- Rooms sharing an identical (x,y,z) cell (distinct rooms overlapping).
    local coordCount = {}

    for i, rid in ipairs(roomIDs) do
        local rx, ry, rz = coords_of(rid)
        if rx ~= nil then
            local ck = rx .. "," .. ry .. "," .. rz
            coordCount[ck] = (coordCount[ck] or 0) + 1
        end
        local exits = exitsOf[i]
        local hasAnyExit = false

        if exits then
            for dir, targetID in pairs(exits) do
                if type(targetID) == "string" then targetID = tonumber(targetID) end
                if type(targetID) == "number" and targetID > 0 then
                    hasAnyExit = true

                    -- Self-loop
                    if targetID == rid then
                        counts.self_loops = counts.self_loops + 1
                    else
                        local targetAreaID
                        if areaID then targetAreaID = area_of(targetID) end

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
                                local tx, ty, tz = coords_of(targetID)
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

    -- Distinct rooms sharing a cell: every occupant beyond the first is an overlap.
    for _k, n in pairs(coordCount) do
        if n > 1 then
            counts.overlapping_rooms = counts.overlapping_rooms + (n - 1)
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

-- Build a reverse exit index for the given target rooms:
--   index[targetID] = { {sourceID, kind="normal", dir=...}, {sourceID, kind="special", cmd=...}, ... }
--
-- Sources are scanned across ALL areas, because an exit into a room can come
-- from anywhere and Mudlet does not clean up exits pointing at a deleted room.
-- That makes this a whole-world walk (getRooms plus getRoomExits and
-- getSpecialExitsSwap per room), so it must be built ONCE per batch of merges
-- and threaded through, never rebuilt per merge.  merge_duplicate_room keeps
-- whatever index it is handed up to date as it rewires exits, so a survivor
-- that later becomes a loser still has a complete inbound list.
function _.build_reverse_exit_index(targetIDs)
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
--  - Deletes the loser and, if Mudlet accepted the delete, drops it from posCache.
-- `revIndex` is the reverse exit index produced by _.build_reverse_exit_index.
-- Pass it whenever more than one merge is possible: it is mutated in place to
-- stay accurate as exits are rewired, so one index serves a whole batch.  Nil
-- falls back to a one-off whole-world scan for this loser alone, which is only
-- acceptable for a genuinely isolated merge.
function _.merge_duplicate_room(survivorID, loserID, posCache, revIndex)
    if survivorID == loserID then return end
    if type(survivorID) ~= "number" or survivorID < 1 then return end
    if type(loserID) ~= "number" or loserID < 1 then return end

    -- Keep a caller-supplied index in step with the rewiring below, so a batch
    -- can build it once.  Without this a survivor that later becomes a loser
    -- would be missing every inbound exit it inherited here, and those sources
    -- would be left pointing at a deleted room.
    local function note_inbound(targetID, entry)
        if revIndex == nil then return end
        if type(targetID) ~= "number" or targetID < 1 then return end
        local list = revIndex[targetID]
        if list == nil then
            list = {}
            revIndex[targetID] = list
        end
        list[#list + 1] = entry
    end

    -- A source recorded before an earlier merge may itself have been deleted
    -- since.  Mudlet leaves ghost IDs behind, and writing an exit onto one can
    -- resurrect it, so re-check the source is still a live room.
    local function source_is_live(rid)
        if type(rid) ~= "number" or rid < 1 then return false end
        local a = getRoomArea(rid)
        return type(a) == "number" and a > 0
    end

    -- 1. Rewrite inbound exits: normal
    local inboundList = revIndex and (revIndex[loserID] or {}) or (function()
        local tmp = {}
        local idx = _.build_reverse_exit_index({ loserID })
        for _i, entry in ipairs(idx[loserID] or {}) do tmp[#tmp + 1] = entry end
        return tmp
    end)()

    for _i, entry in ipairs(inboundList) do
        local src = entry.sourceID
        if src ~= loserID and source_is_live(src) then
            if entry.kind == "normal" then
                local dir = entry.dir
                -- Normalise numeric dir keys to string names (Mudlet sometimes returns ints)
                if type(dir) == "number" then dir = _.stubmapFlipped[dir] end
                if type(dir) == "string" then
                    pcall(setExit, src, survivorID, dir)
                    note_inbound(survivorID, { sourceID = src, kind = "normal", dir = dir })
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
                local cmd = entry.cmd
                if type(addSpecialExit) == "function" and type(clearSpecialExit) == "function" then
                    pcall(clearSpecialExit, src, cmd)
                    pcall(addSpecialExit, src, survivorID, cmd)
                    note_inbound(survivorID, { sourceID = src, kind = "special", cmd = cmd })
                end
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
                    note_inbound(tgt, { sourceID = survivorID, kind = "normal", dir = dir })
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
                        note_inbound(tgt, { sourceID = survivorID, kind = "special", cmd = cmd })
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

    -- 6. Delete the loser room, then drop it from posCache.  The coords have to
    --    be read first (they are unreadable once the room is gone) but the cache
    --    edit waits for the delete to be confirmed: callers now thread one cache
    --    through a whole normalize instead of rebuilding between passes, so a
    --    room dropped from the cache that Mudlet in fact kept would stay
    --    invisible to every later pass rather than reappearing on the next build.
    local lx, ly, lz = getRoomCoordinates(loserID)
    local deleted    = _.delete_room(loserID)

    -- 7. Drop loser from posCache
    if posCache and deleted then
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

    -- 8. The loser is gone; its inbound list has been transferred to the
    --    survivor, and source_is_live above skips any entry still naming it.
    if revIndex then revIndex[loserID] = nil end
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
    local revIndex = _.build_reverse_exit_index(losers)

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
            _.set_room_coordinates(rid, rx + dx, ry + dy, rz, posCache)
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

-- Best-effort extraction of an "area vnum" from a room hash/vnum.
-- Supported shapes:
--   "<area>:<room>", "<area>/<room>", "<area>.<room>", "<area>-<room>"
-- where area/room segments are numeric.
function _.extract_area_vnum_key(roomHash)
    if type(roomHash) ~= "string" or roomHash == "" then return nil end

    local areaPart = roomHash:match("^(%d+):%d+$")
        or roomHash:match("^(%d+)/%d+$")
        or roomHash:match("^(%d+)%.%d+$")
        or roomHash:match("^(%d+)%-%d+$")

    if type(areaPart) == "string" and areaPart ~= "" then
        return areaPart
    end
    return nil
end

-- Infer an area's "area vnum key" by majority vote across its room hashes.
function _.infer_area_vnum_key_for_area(areaID)
    if type(areaID) ~= "number" or areaID < 1 then return nil, 0 end
    if type(getAreaUserData) == "function" then
        local gmcpKey = getAreaUserData(areaID, "gmcp_area_key")
        if type(gmcpKey) == "string" and gmcpKey ~= "" then
            return gmcpKey, math.huge
        end
    end

    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" or #rooms == 0 then
        local areaName = _.get_area_name_by_id(areaID)
        local numericNameKey = type(areaName) == "string" and areaName:match("^%s*(%d+)%s*$") or nil
        if numericNameKey then
            return numericNameKey, 1
        end
        return nil, 0
    end
    if type(getRoomHashByID) ~= "function" then return nil, 0 end

    local counts = {}
    local bestKey, bestCount = nil, 0
    for _i, rid in ipairs(rooms) do
        local roomHash = getRoomHashByID(rid)
        local key = _.extract_area_vnum_key(roomHash)
        if key then
            local nextCount = (counts[key] or 0) + 1
            counts[key] = nextCount
            if nextCount > bestCount then
                bestKey = key
                bestCount = nextCount
            end
        end
    end

    if bestKey then
        return bestKey, bestCount
    end

    local areaName = _.get_area_name_by_id(areaID)
    local numericNameKey = type(areaName) == "string" and areaName:match("^%s*(%d+)%s*$") or nil
    if numericNameKey then
        return numericNameKey, 1
    end

    return nil, 0
end

local function is_meaningful_area_name(areaName)
    if type(areaName) ~= "string" then return false end
    local trimmed = areaName:match("^%s*(.-)%s*$")
    if trimmed == "" then return false end

    local lower = trimmed:lower()
    if lower == "unnamed" then return false end
    if lower:match("^unnamed%s*area") then return false end
    if lower:match("^area%s*%d+$") then return false end
    if trimmed:match("^%d+$") then return false end
    return true
end

local function get_area_room_count(areaID)
    local rooms = getAreaRooms(areaID)
    return (type(rooms) == "table" and #rooms) or 0
end

-- Merge any areas that resolve to the same inferred area-vnum key as anchorAreaID.
-- Returns:
--   { area_vnum_key=string|nil, merged_areas=N, moved_rooms=M }
function _.merge_duplicate_areas_by_area_vnum(anchorAreaID)
    local result = {
        area_vnum_key = nil,
        merged_areas = 0,
        moved_rooms = 0,
        removed_areas = 0,
        target_area_id = anchorAreaID,
        target_area_name = _.get_area_name_by_id(anchorAreaID),
    }
    if type(anchorAreaID) ~= "number" or anchorAreaID < 1 then return result end

    local anchorKey = _.infer_area_vnum_key_for_area(anchorAreaID)
    result.area_vnum_key = anchorKey
    if not anchorKey then return result end

    local areas = getAreaTable()
    if type(areas) ~= "table" then return result end

    local duplicateAreaIDs = { anchorAreaID }
    for _name, id in pairs(areas) do
        if id ~= anchorAreaID then
            local otherKey = _.infer_area_vnum_key_for_area(id)
            if otherKey == anchorKey then
                duplicateAreaIDs[#duplicateAreaIDs + 1] = id
            end
        end
    end

    local targetAreaID = anchorAreaID
    local anchorName = _.get_area_name_by_id(anchorAreaID)
    local targetNamed = is_meaningful_area_name(anchorName)

    if not targetNamed then
        local bestNamedID = nil
        local bestNamedRooms = -1
        for _, id in ipairs(duplicateAreaIDs) do
            local areaName = _.get_area_name_by_id(id)
            if is_meaningful_area_name(areaName) then
                local roomCount = get_area_room_count(id)
                if roomCount > bestNamedRooms then
                    bestNamedID = id
                    bestNamedRooms = roomCount
                end
            end
        end
        if type(bestNamedID) == "number" and bestNamedID > 0 then
            targetAreaID = bestNamedID
        end
    end

    result.target_area_id = targetAreaID
    result.target_area_name = _.get_area_name_by_id(targetAreaID)

    local function retarget_or_clear_cached_area_ids(fromAreaID, toAreaID)
        if type(map.configs) ~= "table" or type(map.configs.area_ids_by_gmcp) ~= "table" then
            return
        end
        for gmcpKey, mappedID in pairs(map.configs.area_ids_by_gmcp) do
            if mappedID == fromAreaID then
                if type(toAreaID) == "number" and toAreaID > 0 then
                    map.configs.area_ids_by_gmcp[gmcpKey] = toAreaID
                else
                    map.configs.area_ids_by_gmcp[gmcpKey] = nil
                end
            end
        end
    end

    local function maybe_delete_empty_area(areaID)
        local roomsAfterMerge = getAreaRooms(areaID)
        if type(roomsAfterMerge) == "table" and #roomsAfterMerge > 0 then
            return false
        end

        retarget_or_clear_cached_area_ids(areaID, targetAreaID)

        local deleted = false
        if type(deleteArea) == "function" then
            deleted = pcall(deleteArea, areaID) and true or false
        end
        if not deleted and type(deleteAreaName) == "function" then
            local areaName = _.get_area_name_by_id(areaID)
            if type(areaName) == "string" and areaName ~= "" then
                deleted = pcall(deleteAreaName, areaName) and true or false
            end
        end
        -- The area ID is gone and Mudlet may hand it out again for a new area.
        -- Drop everything keyed by it so the next area cannot inherit a stale
        -- room count or a stale hash/name index.
        if deleted then
            _.invalidate_area_room_count(areaID)
            _.invalidate_area_index(areaID)
        end
        return deleted
    end

    for _, id in ipairs(duplicateAreaIDs) do
        if id ~= targetAreaID then
            local otherRooms = getAreaRooms(id)
            local movedThisArea = 0
            if type(otherRooms) == "table" and #otherRooms > 0 then
                for _, rid in ipairs(otherRooms) do
                    if getRoomArea(rid) ~= targetAreaID then
                        _.set_room_area(rid, targetAreaID)
                        movedThisArea = movedThisArea + 1
                    end
                end
            end
            if movedThisArea > 0 then
                result.merged_areas = result.merged_areas + 1
                result.moved_rooms = result.moved_rooms + movedThisArea
                local mergedKey = type(getAreaUserData) == "function"
                    and getAreaUserData(id, "gmcp_area_key") or nil
                if type(mergedKey) == "string" and mergedKey ~= "" then
                    map.configs.area_ids_by_gmcp[mergedKey] = targetAreaID
                    setAreaUserData(targetAreaID, "gmcp_area_key", mergedKey)
                end
                if type(deleteAreaUserData) == "function" then
                    pcall(deleteAreaUserData, id, "gmcp_area_key")
                end
            end

            if maybe_delete_empty_area(id) then
                result.removed_areas = result.removed_areas + 1
            end
        end
    end

    if type(map.room_info.area) == "string" and map.room_info.area ~= "" then
        map.configs.area_ids_by_gmcp[map.room_info.area] = targetAreaID
        setAreaUserData(targetAreaID, "gmcp_area_key", map.room_info.area)
    end

    return result
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
