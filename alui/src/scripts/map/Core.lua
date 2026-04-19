-- Mapping Script — Core
-- Room creation, GMCP event queue, handle_move, shift_room.

-- Guard: ensure map._ exists even if Data.lua evaluated after this chunk.
map     = map or {}
map._   = map._ or {}
local _ = map._

-- Lua 5.1 does not have table.is_empty; Mudlet adds it but provide a fallback
-- so the script is not fragile if Mudlet's version is unavailable.
local function is_empty_t(t)
    return t == nil or next(t) == nil
end

-- --------------------------------------------------------------------------
-- Queue state (local to this chunk, only needed by handle_move and eventHandler)
-- --------------------------------------------------------------------------
local room_event_queue    = {}
local queue_processing    = false
local queue_drain_timer   = nil
local queue_timer_pending = false -- prevents scheduling a second drain timer

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
    local info   = map.room_info
    local coords = { 0, 0, 0 }
    local areaID = resolve_area_id_for_room_info(info)
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
                for _, probe in ipairs(probes) do
                    local testCoords = { coords[1] + probe[1], coords[2] + probe[2], coords[3] + probe[3] }
                    if is_empty_t(getRoomsByPosition(areaID, testCoords[1], testCoords[2], testCoords[3])) then
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
                local overlap = getRoomsByPosition(areaID, coords[1], coords[2], coords[3])
                if not is_empty_t(overlap) then
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
    -- Adjust z-level for elevated/surface transitions on first visit.
    local currEL = _.is_elevated_room_name(info.name)
    local prevEL = _.is_elevated_room_name(map.prev_info.name or "")
    if currEL and not prevEL then
        coords[3] = coords[3] + 1
    elseif not currEL and prevEL then
        coords[3] = coords[3] - 1
    end
    local thisRoom = createRoomID()
    addRoom(thisRoom)
    _.mark_autowalk_dirty()
    setRoomIDbyHash(thisRoom, info.vnum)
    setRoomName(thisRoom, info.name)
    setRoomArea(thisRoom, areaID)
    setRoomCoordinates(thisRoom, coords[1], coords[2], coords[3])
    _.apply_current_room_environment(thisRoom, info.terrain)
    if getRoomChar(thisRoom) == "#" then
        _.apply_room_environment(thisRoom, "Inside")
    end
    if type(info.terrain) == "string" and info.terrain ~= ""
        and not _.is_elevated_room_name(info.name) then
        setRoomUserData(thisRoom, "terrain", info.terrain)
    end
    for dir, id in pairs(info.exits) do
        if type(id) == "string" then
            local rid = getRoomIDbyHash(id)
            _.ensure_exit_stub(thisRoom, dir)
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

-- --------------------------------------------------------------------------
-- shift_room (invoked by the "shiftRoom" event)
-- --------------------------------------------------------------------------

local function shift_room(dir)
    if type(map.room_info.vnum) ~= "string" then
        return
    end

    if type(map.room_info.vnum) == "string" then
        local ID         = getRoomIDbyHash(map.room_info.vnum)
        local x, y, z    = getRoomCoordinates(ID)
        local x1, y1, z1 = unpack(_.move_vectors[dir])
        x                = x + x1
        y                = y + y1
        z                = z + z1
        setRoomCoordinates(ID, x, y, z)
        updateMap()
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
        if type(rnum) ~= "number" then rnum = -1 end
        if rnum < 1 then
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
                    setRoomIDbyHash(placeholderID, info.vnum)
                    _.mark_autowalk_dirty()
                    rnum    = placeholderID
                    adopted = true
                    _.debug_echo("Adopted placeholder " .. placeholderID
                        .. " for vnum " .. info.vnum .. " (dir " .. arrivalDir .. ")\n")
                end
            end
            if not adopted then
                make_room()
                rnum = getRoomIDbyHash(info.vnum)
                if type(rnum) ~= "number" then rnum = -1 end
            end
        end

        if rnum > 0 then
            -- Check if room needs to be moved to its correct area.
            local correctAreaID = resolve_area_id_for_room_info(info)
            local currentAreaID = getRoomArea(rnum)
            if correctAreaID and correctAreaID > 0 and correctAreaID ~= currentAreaID then
                _.debug_echo("Moving room " ..
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

            if type(info.name) == "string" and info.name ~= "" then
                setRoomName(rnum, info.name)
            end

            -- Correct z-level for elevated/surface transitions on rooms that
            -- were pre-created as placeholders at the wrong z.
            local currEL = _.is_elevated_room_name(info.name)
            local prevEL = _.is_elevated_room_name(map.prev_info.name or "")
            if currEL ~= prevEL and type(map.prev_info.vnum) == "string" then
                local prevID = getRoomIDbyHash(map.prev_info.vnum)
                if prevID > 0 then
                    local px, py, pz = getRoomCoordinates(prevID)
                    if pz ~= nil then
                        local expectedZ = currEL and (pz + 1) or (pz - 1)
                        local rx, ry, rz = getRoomCoordinates(rnum)
                        if rz ~= expectedZ then
                            setRoomCoordinates(rnum, rx, ry, expectedZ)
                        end
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
                setRoomUserData(rnum, "terrain", info.terrain)
            else
                _.clear_room_user_data(rnum, "terrain")
            end

            if currentAreaID and currentAreaID > 0 then
                if type(setGridMode) == "function" then
                    setGridMode(currentAreaID, _.current_room_uses_grid_mode())
                end
            end

            local stubs = getExitStubs1(rnum)
            _.debug_echo("Exit stubs for current room: " .. yajl.to_string(stubs) .. "\n")

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

            local newRooms = type(_.create_neighbors_for_current_room) == "function"
                and _.create_neighbors_for_current_room(rnum) or 0
            if isLastInBatch then
                if map.configs.auto_reconcile and newRooms and newRooms > 0 then
                    -- Limit BFS depth so the reconcile stays local on large maps.
                    -- The full-area reconcile is available via 'map normalize'.
                    _.reconcile_connected_rooms(rnum, nil, nil, 5)
                end
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
    while #room_event_queue > 0 do
        local snapshot = table.remove(room_event_queue, 1)
        local ok, err  = pcall(function()
            map.prev_info = map.room_info
            map.room_info = snapshot
            local isLast  = (#room_event_queue == 0)
            handle_move(isLast)
        end)
        if not ok then
            local msg = "Mapper queue error: " .. tostring(err) .. "\n"
            if type(cecho) == "function" then
                cecho("<red>" .. msg .. "<reset>")
            else
                echo(msg)
            end
            if type(debugc) == "function" then debugc(msg) end
        end
    end
    queue_processing  = false
    queue_drain_timer = nil
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
        table.insert(room_event_queue, snapshot)
        if not queue_processing and not queue_timer_pending then
            queue_timer_pending = true
            queue_processing    = true
            queue_drain_timer   = tempTimer(0, function() process_room_queue() end)
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
        config()
        if _.register_mapper_context_menu then
            _.register_mapper_context_menu()
        end
    end
end
