-- Mapping Script — Core
-- Room creation, GMCP event queue, handle_move, shift_room.

-- Guard: ensure map._ exists even if Data.lua evaluated after this chunk.
map     = map or {}
map._   = map._ or {}
local _ = map._

-- --------------------------------------------------------------------------
-- Queue state (local to this chunk, only needed by handle_move and eventHandler)
-- --------------------------------------------------------------------------
-- The queue is drained through a head index rather than table.remove(q, 1):
-- removing the front entry shifts every remaining one, which turns a burst of
-- n events into O(n^2) work exactly when the client is already behind.
local room_event_queue    = {}
local queue_head          = 1     -- next entry to drain
local queue_tail          = 0     -- last entry queued; empty while tail < head
local queue_processing    = false
local queue_drain_timer   = nil
local queue_timer_pending = false -- prevents scheduling a second drain timer
local queue_max_per_tick  = 3     -- process a small batch each timer tick
-- Hard cap on the backlog.  The coalescing in map.eventHandler only merges
-- consecutive events for the same room, so a server alternating between two
-- vnums — or simply emitting Room.Info faster than we drain — would otherwise
-- grow this table without bound.  Reaching the cap means the map is already
-- hopelessly behind the player, so the oldest entries are dropped in order to
-- stay current with where the player actually is.
local queue_max_length    = 200

-- --------------------------------------------------------------------------
-- Deferred neighbour-wiring queue
-- --------------------------------------------------------------------------
-- The second, lower-priority queue.  handle_move used to wire every exit of the
-- arriving room before it returned, which on a large area is the whole cost of
-- a step (measured: create_neighbors_for_current_room accounted for 9157ms of
-- handle_move's 9160ms over seven arrivals).  None of it can move off the main
-- thread — Mudlet's map API is main-thread-only and its C functions are not
-- safe to call from a coroutine — so the only lever is to stop doing it all at
-- once.
--
-- One entry is one exit of one room, because that is the largest unit that
-- still fits in a single tick: a setExit is ~100ms and a placeholder's
-- setRoomArea ~390ms, against ~1.3s for a whole room.
--
-- Deferring also makes some of the work disappear.  An exit queued while the
-- player stood in A is wired after they have already walked to B, by which
-- point B exists as a real room, so the entry costs one setExit instead of
-- creating a placeholder to stand in for it.
local neighbor_queue           = {}
local neighbor_head            = 1
local neighbor_tail            = 0
local neighbor_index           = {} -- "roomID\0dir" -> slot, for coalescing
local neighbor_timer_pending   = false
local process_neighbor_queue        -- forward declaration; defined below

local function neighbor_backlog()
    if neighbor_head > neighbor_tail then return 0 end
    return neighbor_tail - neighbor_head + 1
end
_.neighbor_backlog = neighbor_backlog

local function schedule_neighbor_drain(delay)
    if neighbor_timer_pending then return end
    if neighbor_head > neighbor_tail then return end
    neighbor_timer_pending = true
    tempTimer(delay or 0, function() process_neighbor_queue() end)
end

-- Queue every exit of `info` as its own unit of work for `roomID`.
local function queue_neighbor_wiring(roomID, info)
    if type(roomID) ~= "number" or roomID < 1 then return end
    if type(info) ~= "table" or type(info.exits) ~= "table" then return end
    for dir, targetVnum in pairs(info.exits) do
        if type(targetVnum) == "string" then
            -- Coalesce on room+direction.  Pacing back and forth along a
            -- corridor re-announces the same exits every step, and without this
            -- the queue would fill with restatements of work already pending.
            -- The newest payload wins: it is the one GMCP most recently claimed.
            local key  = roomID .. "\0" .. tostring(dir)
            local slot = neighbor_index[key]
            local held = slot and neighbor_queue[slot] or nil
            if held then
                held.targetVnum = targetVnum
                held.vnum       = info.vnum
            else
                neighbor_tail                = neighbor_tail + 1
                neighbor_queue[neighbor_tail] = {
                    roomID     = roomID,
                    vnum       = info.vnum,
                    dir        = dir,
                    targetVnum = targetVnum,
                }
                neighbor_index[key] = neighbor_tail
            end
        end
    end
    schedule_neighbor_drain()
end

-- Wire one queued exit.  Re-validates first: the entry may have sat in the
-- queue while a dedup pass deleted the room, or while Mudlet handed its id out
-- again, so acting on a stale id could write an exit onto an unrelated room.
local function wire_one_exit(item)
    local roomID = item.roomID
    local areaID = getRoomArea(roomID)
    if type(areaID) ~= "number" or areaID < 1 then return end
    if type(item.vnum) == "string" and item.vnum ~= ""
        and type(getRoomHashByID) == "function" then
        local h = getRoomHashByID(roomID)
        -- An empty hash is not a mismatch: plenty of legitimate rooms carry
        -- none.  Only a hash that has become a *different* vnum means this id
        -- no longer refers to the room the entry was queued for.
        if type(h) == "string" and h ~= "" and h ~= item.vnum then return end
    end
    if type(_.create_neighbors_for_current_room) ~= "function" then return end
    local posCache = type(_.live_pos_cache) == "function" and _.live_pos_cache(areaID) or nil
    _.create_neighbors_for_current_room(roomID, posCache,
        { exits = { [item.dir] = item.targetVnum } })
end

process_neighbor_queue = function()
    neighbor_timer_pending = false
    if neighbor_head > neighbor_tail then
        neighbor_queue, neighbor_index = {}, {}
        neighbor_head, neighbor_tail   = 1, 0
        return
    end

    local backlog = neighbor_backlog()
    local softCap = tonumber(map.configs.deferred_neighbor_soft_cap) or 2000
    local perTick = tonumber(map.configs.deferred_neighbor_per_tick) or 1
    if perTick < 1 then perTick = 1 end

    -- Arrivals come first.  While room events are still queued the player is
    -- ahead of the map, and wiring rooms they have already left would add to
    -- the lag they can actually see.  Past the soft cap that deference stops,
    -- because the backlog has to be bounded by something and dropping entries
    -- is not an option: a missing forward exit is a hole in the graph that both
    -- map normalize and map recalculate navigate by.
    if queue_head <= queue_tail and backlog < softCap then
        schedule_neighbor_drain(0.1)
        return
    end
    if backlog >= softCap then
        perTick = perTick + math.floor(backlog / softCap)
    end

    local done = 0
    while neighbor_head <= neighbor_tail and done < perTick do
        local item                    = neighbor_queue[neighbor_head]
        neighbor_queue[neighbor_head] = nil
        neighbor_head                 = neighbor_head + 1
        if item then
            neighbor_index[item.roomID .. "\0" .. tostring(item.dir)] = nil
            -- Scope closed outside the pcall so an error still ends it.
            _.prof_enter("wire_exit")
            local ok, err = pcall(wire_one_exit, item)
            _.prof_exit()
            if not ok then
                local msg = "Mapper deferred-wiring error: " .. tostring(err) .. "\n"
                if type(cecho) == "function" then
                    cecho("<red>" .. msg .. "<reset>")
                else
                    echo(msg)
                end
                if type(debugc) == "function" then debugc(msg) end
            end
        end
        done = done + 1
    end

    if neighbor_head > neighbor_tail then
        neighbor_queue, neighbor_index = {}, {}
        neighbor_head, neighbor_tail   = 1, 0
    else
        schedule_neighbor_drain()
    end
end

-- vertical directions used by check_doors (exposed here for event handler)
local verticalDirs        = { u = true, up = true, d = true, down = true }

-- --------------------------------------------------------------------------
-- Room creation helpers
-- --------------------------------------------------------------------------

local function resolve_area_id_for_room_info(info)
    local gmcpArea = info and info.area
    if type(gmcpArea) ~= "string" or gmcpArea == "" then
        return nil
    end

    local cachedAreaID = tonumber(map.configs.area_ids_by_gmcp[gmcpArea])
    if cachedAreaID and cachedAreaID > 0 then
        return cachedAreaID
    end

    local areas  = getAreaTable()
    local areaID = type(areas) == "table" and areas[gmcpArea] or nil

    if not areaID and type(areas) == "table" then
        for _name, id in pairs(areas) do
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
    local info   = map.room_info
    local coords = { 0, 0, 0 }
    local areaID = resolve_area_id_for_room_info(info)
    -- make_room runs before handle_move's posCache block, so it looks the
    -- long-lived cache up itself: occupancy probes below are answered from it
    -- when we hold one for this area (nil just means the probes fall back to
    -- getRoomsByPosition), and every coordinate write here is mirrored into it.
    local posCache = areaID and _.live_pos_cache(areaID) or nil
    if not areaID then
        echo("Cannot create room: area could not be resolved.\n")
        return
    else
        if type(map.prev_info.vnum) == "string" then
            local prevID = getRoomIDbyHash(map.prev_info.vnum)
            if type(prevID) == "number" and prevID > 0 then
                coords = { getRoomCoordinates(prevID) }
            end
            if coords[1] == nil then coords = { 0, 0, 0 } end
            local shift = { 0, 0, 0 }
            if type(info.exits) == "table" then
                for k, v in pairs(info.exits) do
                    if v == map.prev_info.vnum and _.move_vectors[k] then
                        shift = _.move_vectors[k]
                        break
                    end
                end
            end
            -- Fallback 1: prev room had a directional exit leading to this room.
            if shift[1] == 0 and shift[2] == 0 and shift[3] == 0 then
                if type(map.prev_info.exits) == "table" then
                    for k, v in pairs(map.prev_info.exits) do
                        if v == info.vnum and _.move_vectors[k] then
                            local rev = _.reverse_move_vectors[k]
                            if rev then shift = _.move_vectors[rev] end
                            break
                        end
                    end
                end
            end
            -- Fallback 2: infer vertical offset from the special exit name.
            if shift[1] == 0 and shift[2] == 0 and shift[3] == 0 then
                if type(map.prev_info.exits) == "table" then
                    for k, v in pairs(map.prev_info.exits) do
                        if v == info.vnum and not _.move_vectors[k] then
                            local g = _.guess_vertical_shift(k)
                            if g then shift = { -g[1], -g[2], -g[3] } end
                            break
                        end
                    end
                end
                if shift[1] == 0 and shift[2] == 0 and shift[3] == 0 then
                    if type(info.exits) == "table" then
                        for k, v in pairs(info.exits) do
                            if v == map.prev_info.vnum and not _.move_vectors[k] then
                                local g = _.guess_vertical_shift(k)
                                if g then shift = g end
                                break
                            end
                        end
                    end
                end
            end
            -- Fallback 3: no directional clue — probe adjacent positions.
            if shift[1] == 0 and shift[2] == 0 and shift[3] == 0 then
                local probes = { { 0, 0, 1 }, { 0, 0, -1 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 } }
                -- Loop var must not be named `_`: that is the module table
                -- (`local _ = map._`) and shadowing it breaks `_.` calls below.
                for _i, probe in ipairs(probes) do
                    local testCoords = { coords[1] + probe[1], coords[2] + probe[2], coords[3] + probe[3] }
                    if _.rooms_at_position(posCache, areaID,
                            testCoords[1], testCoords[2], testCoords[3]) == nil then
                        shift = { -probe[1], -probe[2], -probe[3] }
                        break
                    end
                end
            end
            for n = 1, 3 do
                coords[n] = coords[n] - shift[n]
            end
            -- Map stretching (skip while grid mode is active)
            if not _.should_skip_stretch_for_area(areaID) then
                local overlap = _.rooms_at_position(posCache, areaID,
                    coords[1], coords[2], coords[3])
                if overlap ~= nil then
                    local rooms = getAreaRooms(areaID)
                    local rcoords
                    for _i, id in ipairs(rooms) do
                        rcoords = { getRoomCoordinates(id) }
                        -- Skip rooms that have no coordinates yet; the
                        -- arithmetic below would fault on the nil.
                        if rcoords[1] ~= nil then
                            for n = 1, 3 do
                                if shift[n] ~= 0 and (rcoords[n] - coords[n]) * shift[n] <= 0 then
                                    rcoords[n] = rcoords[n] - shift[n]
                                end
                            end
                            -- Through the wrapper: this shifts the whole area,
                            -- so an unmirrored write would invalidate every
                            -- cell in the cache at once.
                            _.set_room_coordinates(id, rcoords[1], rcoords[2], rcoords[3], posCache)
                        end
                    end
                end
            end
        end
    end
    -- Adjust z-level for elevated/surface transitions on first visit.
    local currEL = _.is_elevated_room_name(info.name)
    local prevEL = _.is_elevated_room_name(map.prev_info.name or "")
    if currEL and not prevEL then
        coords[3] = coords[3] + 1
    elseif not currEL and prevEL then
        coords[3] = coords[3] - 1
    end
    local thisRoom = createRoomID()
    _.add_room(thisRoom)
    _.mark_autowalk_dirty()
    -- The index updates take areaID explicitly because the room does not have
    -- an area yet: set_room_area is the next line down.
    _.bind_room_hash(thisRoom, info.vnum, areaID)
    _.set_room_name(thisRoom, info.name, areaID)
    _.set_room_area(thisRoom, areaID)
    _.set_room_coordinates(thisRoom, coords[1], coords[2], coords[3], posCache)
    -- Loud warning when we end up creating a brand-new room near the
    -- area origin without a directional shift — this almost always means
    -- the prior locked/anchor room lost its hash binding somewhere and we
    -- are about to "teleport" the player to (0,0,0).  The user explicitly
    -- asked us to surface this case so it is no longer silent.
    if math.abs(coords[1]) <= 2 and math.abs(coords[2]) <= 2 and math.abs(coords[3]) <= 2 then
        local msg = string.format(
            "make_room: created room %d for vnum %s at (%d,%d,%d). "
            .. "If this is unexpected, an earlier code path may have cleared "
            .. "the previous room's hash binding.\n",
            thisRoom, tostring(info.vnum), coords[1], coords[2], coords[3])
        if type(cecho) == "function" then
            cecho("<yellow>" .. msg .. "<reset>")
        else
            echo(msg)
        end
        if type(_.debug_echo) == "function" then _.debug_echo(msg) end
    end
    _.apply_current_room_environment(thisRoom, info.terrain)
    if getRoomChar(thisRoom) == "#" then
        _.apply_room_environment(thisRoom, "Inside")
    end
    if type(info.terrain) == "string" and info.terrain ~= ""
        and not _.is_elevated_room_name(info.name) then
        local storedTerrain = _.normalize_terrain_name(info.terrain)
        if storedTerrain then
            setRoomUserData(thisRoom, "terrain", storedTerrain)
        end
    end
    for dir, id in pairs(info.exits) do
        if type(id) == "string" then
            local rid = getRoomIDbyHash(id)
            if type(rid) == "number" and rid > 0 then
                -- Wire it directly.  Creating a stub and connecting it in the
                -- same breath costs a connectExitStub, measured at ~138ms on a
                -- large area against ~101ms for the setExit that does the same
                -- job.  Only a stub left over from an earlier visit needs the
                -- connect form, since setExit would leave that stub behind.
                if type(_.room_has_exit_stub) == "function"
                    and _.room_has_exit_stub(thisRoom, dir) then
                    connectExitStub(thisRoom, rid, dir)
                else
                    setExit(thisRoom, rid, dir)
                end
            else
                _.ensure_exit_stub(thisRoom, dir)
            end
        end
    end
    if thisRoom ~= nil then
        centerview(thisRoom)
    end
end

map.make_room = make_room

-- --------------------------------------------------------------------------
-- shift_room (invoked by the "shiftRoom" event)
-- --------------------------------------------------------------------------

local function shift_room(dir)
    if type(map.room_info.vnum) ~= "string" then
        return
    end

    if type(map.room_info.vnum) == "string" then
        local ID = getRoomIDbyHash(map.room_info.vnum)
        if type(ID) ~= "number" or ID < 1 then return end
        local vec = _.move_vectors[dir]
        if type(vec) ~= "table" then
            echo("map shift: unknown direction '" .. tostring(dir) .. "'.\n")
            return
        end
        local x, y, z = getRoomCoordinates(ID)
        if x == nil then return end
        local x1, y1, z1 = unpack(vec)
        x                = x + x1
        y                = y + y1
        z                = z + z1
        -- No cache in scope here; the wrapper finds the long-lived one itself.
        _.set_room_coordinates(ID, x, y, z)
        -- Pin the room so subsequent layout passes (stretch, reconcile,
        -- recalculate, dedup) cannot drag it back to its old position.
        _.set_room_locked(ID, true)
        _.debug_echo("Shifted room " .. ID .. " to ("
            .. x .. "," .. y .. "," .. z .. ") and locked it.\n")
        updateMap()
        -- Recenter so the player marker visibly follows the shifted room.
        if type(centerview) == "function" then centerview(ID) end
    end
end

_.shift_room = shift_room

-- --------------------------------------------------------------------------
-- handle_move
-- --------------------------------------------------------------------------

local function handle_move(isLastInBatch)
    if isLastInBatch == nil then isLastInBatch = true end
    local info = map.room_info
    if type(info.vnum) ~= "string" then
        return
    end

    if type(info.vnum) == "string" then
        local rnum = getRoomIDbyHash(info.vnum)
        local roomWasCreatedOrAdopted = false
        if type(rnum) ~= "number" then rnum = -1 end
        -- Self-heal a forward/reverse hash-index desync before treating the
        -- room as missing.  A room may still store this hash even when the
        -- reverse lookup fails; without this repair handle_move would fall into
        -- "adopt or create" and spawn placeholder stubs / stacked duplicates.
        if rnum < 1 and type(_.resolve_room_id_by_hash) == "function" then
            rnum = _.resolve_room_id_by_hash(info.vnum, resolve_area_id_for_room_info(info))
            if type(rnum) ~= "number" then rnum = -1 end
        end
        if type(rnum) == "number" and rnum > 0 then
            local areaID = getRoomArea(rnum)
            local rx, ry, rz = getRoomCoordinates(rnum)
            local roomName = getRoomName(rnum)
            local hasName = type(roomName) == "string" and roomName ~= ""
            local hasCoords = rx ~= nil and ry ~= nil and rz ~= nil
            if not areaID or areaID < 1 or (not hasCoords and not hasName) then
                pcall(setRoomIDbyHash, rnum, "")
                rnum = -1
            end
        end
        if rnum < 1 then
            local warn = "handle_move: vnum " .. tostring(info.vnum)
                .. " has no room (getRoomIDbyHash returned " .. tostring(rnum)
                .. "). Will adopt or create — this can place the room near 0,0,0.\n"
            if type(cecho) == "function" then
                cecho("<yellow>" .. warn .. "<reset>")
            else
                echo(warn)
            end
            _.debug_echo(warn)
            -- Before creating a brand-new room, check if there is an existing
            -- placeholder at the expected adjacent position that we can adopt.
            -- This happens during autowalk when a placeholder's stored hash
            -- doesn't match the GMCP vnum we receive on arrival.
            local prevRoomID = type(map.prev_info) == "table"
                and type(map.prev_info.vnum) == "string"
                and getRoomIDbyHash(map.prev_info.vnum) or nil
            local arrivalDir = map.last_walk_dir
            local adopted    = false
            if type(prevRoomID) == "number" and prevRoomID > 0
                and type(arrivalDir) == "string" and arrivalDir ~= ""
                and type(_.find_placeholder_for_arrival) == "function" then
                local placeholderID = _.find_placeholder_for_arrival(prevRoomID, arrivalDir, info.vnum)
                if placeholderID then
                    -- Remap the placeholder's hash → incoming GMCP vnum.
                    -- Best-effort clear the old (stale) hash binding first so it
                    -- can't point at this room ID any more.
                    if type(getRoomHashByID) == "function" then
                        local oldHash = getRoomHashByID(placeholderID)
                        if type(oldHash) == "string" and oldHash ~= "" and oldHash ~= info.vnum then
                            pcall(setRoomIDbyHash, placeholderID, "")
                        end
                    end
                    _.bind_room_hash(placeholderID, info.vnum)
                    _.mark_autowalk_dirty()
                    rnum    = placeholderID
                    adopted = true
                    roomWasCreatedOrAdopted = true
                    _.debug_echo("Adopted placeholder " .. placeholderID
                        .. " for vnum " .. info.vnum .. " (dir " .. arrivalDir .. ")\n")
                end
            end
            if not adopted then
                -- Phase B: try exit-set adoption for un-hashed real rooms (rooms
                -- that already exist in Mudlet's map but have no hash binding yet,
                -- e.g. an existing map imported without GMCP data).
                local adoptAreaID = resolve_area_id_for_room_info(info)
                if adoptAreaID and type(_.find_real_room_to_adopt) == "function" then
                    local adoptedID = _.find_real_room_to_adopt(adoptAreaID)
                    if adoptedID then
                        _.bind_room_hash(adoptedID, info.vnum)
                        _.mark_autowalk_dirty()
                        rnum    = adoptedID
                        adopted = true
                        roomWasCreatedOrAdopted = true
                        _.debug_echo("Adopted real room " .. adoptedID
                            .. " (" .. tostring(info.name) .. ") for vnum " .. info.vnum .. "\n")
                    end
                end
            end
            if not adopted then
                make_room()
                rnum = getRoomIDbyHash(info.vnum)
                if type(rnum) ~= "number" then rnum = -1 end
                if rnum > 0 then
                    roomWasCreatedOrAdopted = true
                end
            end
        end

        if rnum > 0 then
            -- Check if room needs to be moved to its correct area.
            local correctAreaID = resolve_area_id_for_room_info(info)
            local currentAreaID = getRoomArea(rnum)
            local areaMatchesGMCP = not (correctAreaID and correctAreaID > 0 and correctAreaID ~= currentAreaID)
            if correctAreaID and correctAreaID > 0 and correctAreaID ~= currentAreaID then
                local canAutoMoveArea = roomWasCreatedOrAdopted
                    or type(currentAreaID) ~= "number"
                    or currentAreaID < 1
                if canAutoMoveArea then
                    _.debug_echo("Moving room " ..
                        rnum .. " from area " .. currentAreaID .. " to area " .. correctAreaID .. "\n")
                    _.set_room_area(rnum, correctAreaID)
                    currentAreaID = correctAreaID
                    areaMatchesGMCP = true
                else
                    _.debug_echo("Skipping area move for existing room " .. rnum
                        .. " (current area " .. tostring(currentAreaID)
                        .. ", GMCP area " .. tostring(correctAreaID) .. ")\n")
                    areaMatchesGMCP = false
                end
            end

            -- Reuse the area position cache across GMCP events to avoid
            -- rebuilding it (getAreaRooms + N getRoomCoordinates) on every
            -- Room.Info.  It is mutated in place rather than rebuilt: the
            -- lifecycle wrappers (_.set_room_coordinates, _.set_room_area,
            -- _.delete_room) mirror every move, area change and delete into it,
            -- including the ones made by paths that never receive it (map
            -- normalize, map recalculate, make_room's stretch).  That is what
            -- lets _.rooms_at_position trust a miss as "cell is empty" instead
            -- of paying an O(area) getRoomsByPosition to confirm it.  Rebuilt
            -- when the area changes and on reconnect (sysConnectionEvent sets
            -- map._pos_cache = nil); a room moved by Mudlet's own map editor is
            -- the one thing it cannot see.
            -- For large areas the full build would freeze Mudlet for minutes;
            -- use a sentinel (no coord mapping) which rooms_at_position treats
            -- as "no data" and answers from getRoomsByPosition instead.
            local posCache = nil
            if type(currentAreaID) == "number" and currentAreaID > 0
                and type(_.build_pos_cache) == "function" then
                if type(map._pos_cache) ~= "table"
                    or map._pos_cache._areaID ~= currentAreaID then
                    if type(_.is_large_area) == "function"
                        and _.is_large_area(currentAreaID) then
                        map._pos_cache = {
                            _areaID     = currentAreaID,
                            _rooms      = {},
                            _large_area = true,
                        }
                    else
                        map._pos_cache = _.build_pos_cache(currentAreaID)
                    end
                end
                posCache = map._pos_cache
            end

            -- Update the cache with the confirmed correct area ID.
            if areaMatchesGMCP and type(info.area) == "string" and info.area ~= "" then
                if type(currentAreaID) == "number" and currentAreaID > 0 then
                    map.configs.area_ids_by_gmcp[info.area] = currentAreaID
                    setAreaUserData(currentAreaID, "gmcp_area_key", info.area)
                end
            end

            if type(info.name) == "string" and info.name ~= "" then
                if getRoomName(rnum) ~= info.name then
                    _.set_room_name(rnum, info.name, currentAreaID)
                end
            end

            -- Correct z-level for elevated/surface transitions on rooms that
            -- were pre-created as placeholders at the wrong z.
            local currEL = _.is_elevated_room_name(info.name)
            local prevEL = _.is_elevated_room_name(map.prev_info.name or "")
            if currEL ~= prevEL and type(map.prev_info.vnum) == "string"
                and not _.is_room_locked(rnum) then
                local prevID = getRoomIDbyHash(map.prev_info.vnum)
                if prevID > 0 then
                    local px, py, pz = getRoomCoordinates(prevID)
                    if pz ~= nil then
                        local expectedZ = currEL and (pz + 1) or (pz - 1)
                        local rx, ry, rz = getRoomCoordinates(rnum)
                        if rz ~= expectedZ then
                            _.set_room_coordinates(rnum, rx, ry, expectedZ, posCache)
                        end
                    end
                end
            end

            -- Self-heal: if this room is offset from every horizontal
            -- neighbour by the same non-zero dz, snap this room onto their
            -- shared z-plane.  This corrects rooms that were mis-placed by
            -- the (now-fixed) forcedZ override, e.g. a "dense forest" room
            -- at z=0 while its entire cluster lives at z=33.
            -- Only runs when the room is not locked/pinned by the user.
            if not _.is_room_locked(rnum) then
                local rx, ry, rz = getRoomCoordinates(rnum)
                if rx ~= nil and type(info.exits) == "table" then
                    local sharedDz   = nil
                    local consistent = true
                    for dir, targetVnum in pairs(info.exits) do
                        local shift = type(_.get_shift_for_exit_key) == "function"
                            and _.get_shift_for_exit_key(dir) or nil
                        if shift and _.is_horizontal_shift and _.is_horizontal_shift(shift) then
                            local tid = type(targetVnum) == "string"
                                and getRoomIDbyHash(targetVnum) or nil
                            if type(tid) == "number" and tid > 0 then
                                local ta = getRoomArea(tid)
                                if type(ta) == "number" and ta == currentAreaID then
                                    local _tx, _ty, tz2 = getRoomCoordinates(tid)
                                    if tz2 ~= nil then
                                        local dz = tz2 - rz
                                        if dz ~= 0 then
                                            if sharedDz == nil then
                                                sharedDz = dz
                                            elseif sharedDz ~= dz then
                                                consistent = false
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if consistent and sharedDz ~= nil and sharedDz ~= 0 then
                        local newZ = rz + sharedDz
                        _.debug_echo(string.format(
                            "handle_move: self-heal room %d z %d→%d (all horizontal neighbours at z+%d)\n",
                            rnum, rz, newZ, sharedDz))
                        _.set_room_coordinates(rnum, rx, ry, newZ, posCache)
                    end
                end
            end

            _.apply_current_room_environment(rnum, info.terrain)
            if getRoomChar(rnum) == "#" then
                _.apply_room_environment(rnum, "Inside")
            end
            if _.is_elevated_room_name(info.name) then
                _.clear_room_user_data(rnum, "terrain")
            elseif type(info.terrain) == "string" and info.terrain ~= "" then
                local storedTerrain = _.normalize_terrain_name(info.terrain)
                if storedTerrain and getRoomUserData(rnum, "terrain") ~= storedTerrain then
                    setRoomUserData(rnum, "terrain", storedTerrain)
                end
            else
                _.clear_room_user_data(rnum, "terrain")
            end

            if currentAreaID and currentAreaID > 0 then
                if type(setGridMode) == "function" then
                    local desiredGrid = _.current_room_uses_grid_mode() and true or false
                    map._last_grid_mode_by_area = map._last_grid_mode_by_area or {}
                    if map._last_grid_mode_by_area[currentAreaID] ~= desiredGrid then
                        setGridMode(currentAreaID, desiredGrid)
                        map._last_grid_mode_by_area[currentAreaID] = desiredGrid
                    end
                end
            end

            -- Wire the exit we just walked, from the previous room's side.
            --
            -- create_neighbors_for_current_room only ever writes exits of the
            -- room the player is *in*.  The exit from the room they just left to
            -- this one used to exist already, because standing in that room had
            -- created a placeholder here and wired to it, and arriving adopted
            -- the placeholder.  Where unexplored exits are stubs instead nothing
            -- writes it, and the forward graph would then be missing every
            -- connection actually travelled — which is exactly what
            -- reconcile_connected_rooms and map recalculate BFS over to position
            -- rooms, and what snap_vertical_pair needs to align an up/down pair.
            --
            -- The direction comes from the previous room's own GMCP exit list,
            -- so it is that room's authoritative view: one-way passages stay
            -- one-way, because the only exit written is one the server said that
            -- room has.  Runs regardless of the stub setting — with placeholders
            -- the exit already points here and the write is skipped, and where it
            -- does not, the previous room was left pointing at a stale
            -- placeholder and this repairs it.
            do
                local prev = map.prev_info
                if type(prev) == "table" and type(prev.exits) == "table"
                    and type(prev.vnum) == "string" and prev.vnum ~= ""
                    and prev.vnum ~= info.vnum then
                    local fromID = getRoomIDbyHash(prev.vnum)
                    if type(fromID) == "number" and fromID > 0 and fromID ~= rnum then
                        local existing = getRoomExits(fromID)
                        for dir, targetVnum in pairs(prev.exits) do
                            if targetVnum == info.vnum then
                                local exitDir = _.normalize_exit_direction(dir)
                                if not exitDir then
                                    local d = type(dir) == "string" and string.lower(dir) or nil
                                    if d == "in" or d == "out" then exitDir = d end
                                end
                                if exitDir then
                                    local cur = type(existing) == "table" and existing[exitDir] or nil
                                    if type(cur) == "string" then cur = tonumber(cur) end
                                    if cur ~= rnum then
                                        -- connectExitStub is the call that turns
                                        -- an existing stub into a real exit;
                                        -- setExit is for a direction with neither.
                                        if type(_.room_has_exit_stub) == "function"
                                            and _.room_has_exit_stub(fromID, exitDir) then
                                            connectExitStub(fromID, rnum, exitDir)
                                        else
                                            setExit(fromID, rnum, exitDir)
                                        end
                                        if type(existing) == "table" then
                                            existing[exitDir] = rnum
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            local stubs = getExitStubs1(rnum)
            if map.configs.debug_mapper then
                _.debug_echo("Exit stubs for current room: " .. yajl.to_string(stubs) .. "\n")
            end

            if stubs then
                for _i, n in ipairs(stubs) do
                    local dir = _.stubmapFlipped[n]
                    if type(dir) ~= "string" then
                        -- stub number has no named direction; skip
                    elseif info.exits and type(info.exits[dir]) == "string" then
                        local targetVnum = info.exits[dir]
                        local id         = getRoomIDbyHash(targetVnum)
                        if type(id) == "number" and id > 0 and getRoomName(id) then
                            connectExitStub(rnum, id, dir)
                        end
                    end
                end
            end

            -- Neighbour wiring is the whole cost of an arrival on a large area,
            -- so it is queued rather than done here (see the deferred queue at
            -- the top of this file).  Small areas keep wiring inline: every call
            -- involved is sub-millisecond there, so deferring would only make
            -- exits appear late for no gain.
            local deferred = map.configs.defer_neighbor_wiring ~= false
                and type(_.is_large_area) == "function"
                and _.is_large_area(currentAreaID)
            if deferred then
                queue_neighbor_wiring(rnum, info)
            elseif type(_.create_neighbors_for_current_room) == "function" then
                _.create_neighbors_for_current_room(rnum, posCache)
            end
            if isLastInBatch then
                updateMap()
                centerview(rnum)
            end
        end
    end
end

-- --------------------------------------------------------------------------
-- GMCP queue drain
-- --------------------------------------------------------------------------

local function process_room_queue()
    queue_timer_pending = false
    -- Drain a small batch per timer tick. This keeps Mudlet responsive while
    -- reducing visible map lag when Room.Info events arrive in bursts.
    local drained = 0
    while queue_head <= queue_tail and drained < queue_max_per_tick do
        local snapshot               = room_event_queue[queue_head]
        room_event_queue[queue_head] = nil
        queue_head                   = queue_head + 1
        if queue_head > queue_tail then
            -- Drained empty: restart the indices so they cannot climb forever.
            queue_head, queue_tail = 1, 0
        end
        -- Profiler scope for one drained room event.  It sits outside the pcall
        -- so an error inside handle_move still closes it; no-op unless
        -- `map profile on` is active.  This is the unit that matters for the
        -- freeze: everything one arrival costs, including the drain bookkeeping.
        _.prof_enter("handle_move")
        local ok, err = pcall(function()
            -- A gapped entry is the one that followed dropped events, so the
            -- previous snapshot is no longer an adjacent room and make_room
            -- must not infer a movement direction from it.  Empty prev_info is
            -- the state every session already starts in.
            map.prev_info = snapshot._gap and {} or map.room_info
            map.room_info = snapshot
            local isLast  = (queue_head > queue_tail) or (drained == queue_max_per_tick - 1)
            handle_move(isLast)
        end)
        _.prof_exit()
        if not ok then
            local msg = "Mapper queue error: " .. tostring(err) .. "\n"
            if type(cecho) == "function" then
                cecho("<red>" .. msg .. "<reset>")
            else
                echo(msg)
            end
            if type(debugc) == "function" then debugc(msg) end
        end
        drained = drained + 1
    end
    if queue_head <= queue_tail then
        queue_timer_pending = true
        queue_drain_timer   = tempTimer(0, function() process_room_queue() end)
    else
        queue_processing  = false
        queue_drain_timer = nil
    end
end

-- --------------------------------------------------------------------------
-- Config (terrain colours)
-- --------------------------------------------------------------------------

local function config()
    for k, v in pairs(_.terrain_types) do
        setCustomEnvColor(v.id, v.r, v.g, v.b, 255)
    end
end

-- Register colours immediately on script load so placeholder rooms show the
-- correct dimmed colour even before a (re)connection fires sysConnectionEvent.
config()

-- --------------------------------------------------------------------------
-- Event handler (needs access to queue locals defined above)
-- --------------------------------------------------------------------------

function map.eventHandler(event, ...)
    if event == "gmcp.Room.Info" then
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
        -- Coalesce duplicate queued updates for the same room so repeated
        -- Room.Info payloads do not create avoidable queue lag.
        local tail = queue_tail >= queue_head and room_event_queue[queue_tail] or nil
        if tail and tail.vnum == snapshot.vnum then
            snapshot._gap                = tail._gap
            room_event_queue[queue_tail] = snapshot
        else
            queue_tail                   = queue_tail + 1
            room_event_queue[queue_tail] = snapshot
            -- Enforce the backlog cap by dropping from the front; the entry
            -- that becomes the new head is marked as following a gap.
            while queue_tail - queue_head >= queue_max_length do
                room_event_queue[queue_head]      = nil
                queue_head                        = queue_head + 1
                room_event_queue[queue_head]._gap = true
            end
        end
        if not queue_processing and not queue_timer_pending then
            queue_processing = true
            process_room_queue()
        end
        if map.walking and _.get_active_speedwalk_wait and _.get_active_speedwalk_wait()
            and _.get_active_speedwalk_delay and _.get_active_speedwalk_delay() <= 0 then
            if _.continue_walk then _.continue_walk(true) end
        end
    elseif event == "shiftRoom" then
        local args = { ... }
        local dir  = _.exitmap[args[1]] or args[1]
        if not _.move_vectors[dir] then
            echo("Error: Invalid direction '" .. tostring(args[1]) .. "'.")
        else
            shift_room(dir)
        end
    elseif event == "sysConnectionEvent" then
        map._pos_cache       = nil -- force posCache rebuild for the new session's area
        map._area_index      = nil -- ditto for the per-area hash/name index
        -- Pending wiring refers to room ids and vnums from the previous session.
        -- The map file may have been reloaded or edited since, so draining them
        -- now would write exits based on a map that no longer exists.
        neighbor_queue, neighbor_index = {}, {}
        neighbor_head, neighbor_tail   = 1, 0
        -- The map file may have been reloaded or edited between sessions, so
        -- the incremental room counts can no longer be trusted; drop them and
        -- let the next query re-count from getAreaRooms.
        map._area_room_counts = nil
        config()
        if _.register_mapper_context_menu then
            _.register_mapper_context_menu()
        end
    end
end
