-- Mapping Script — Layout
-- Functions that determine and adjust room coordinates:
--   create_neighbors_for_current_room, reconcile_connected_rooms,
--   flatten_cardinal_connected_rooms, map.normalize_room_layout,
--   map.recalculate_room_layout.

map     = map or {}
map._   = map._ or {}
local _ = map._

-- --------------------------------------------------------------------------
-- Placement: neighbours
-- --------------------------------------------------------------------------

function _.create_neighbors_for_current_room(roomID)
    local info = map.room_info
    if type(info.exits) ~= "table" then return end
    if type(roomID) ~= "number" or roomID < 1 then return end

    local areaID = getRoomArea(roomID)
    if not areaID or areaID < 1 then return end

    local cx, cy, cz = getRoomCoordinates(roomID)
    if cx == nil then return end

    local forcedZ      = _.get_forced_z_for_room(roomID)
    local createdCount = 0

    for dir, targetVnum in pairs(info.exits) do
        if type(targetVnum) ~= "string" then
            -- skip bad values
        else
            local shift    = _.get_shift_for_exit_key(dir)

            local targetID = getRoomIDbyHash(targetVnum)
            local created  = false

            if targetID < 1 then
                targetID = createRoomID()
                addRoom(targetID)
                setRoomIDbyHash(targetID, targetVnum)
                created = true
                createdCount = createdCount + 1
                setRoomName(targetID, targetVnum)
                -- Mark as unvisited (dimmed colour) so it is visually distinct
                -- from rooms the player has actually entered.
                _.apply_room_environment(targetID, "unvisited")
            end

            -- Newly created or existing rooms without an area get placed next to us.
            local targetAreaID = getRoomArea(targetID)
            if created or not targetAreaID or targetAreaID < 1 then
                if shift then
                    local tx = cx + shift[1]
                    local ty = cy + shift[2]
                    local tz = cz + shift[3]

                    if forcedZ and shift[3] == 0 then
                        tz = forcedZ
                    end

                    local skipStretch = _.should_skip_stretch_for_area(areaID)
                    _.move_room_to_expected_position(targetID, targetVnum, areaID,
                        { tx, ty, tz }, shift, skipStretch)
                else
                    setRoomArea(targetID, areaID)
                end
            end

            -- Wire up exits.
            if shift then
                local x2, y2, z2 = getRoomCoordinates(targetID)
                if x2 == nil then
                    setRoomCoordinates(targetID, cx + shift[1], cy + shift[2], cz + shift[3])
                end
            end

            -- Set the forward exit from current room to placeholder.
            -- One-directional is intentional: GMCP is authoritative, the reverse
            -- will be set properly when the player actually enters that room.
            -- map recalculate only needs forward exits to BFS-position rooms.
            -- setExit only accepts the 12 standard Mudlet direction names; skip
            -- any non-standard GMCP exit key (portals, custom commands, etc.)
            -- to avoid the "direction as number or string expected" error.
            local exitDir = _.normalize_exit_direction(dir)
            if not exitDir then
                local d = type(dir) == "string" and string.lower(dir) or nil
                if d == "in" or d == "out" then exitDir = d end
            end
            if exitDir then
                setExit(roomID, targetID, exitDir)
            end
        end
    end
    if createdCount > 0 then
        _.mark_autowalk_dirty()
    end
    return createdCount
end

-- --------------------------------------------------------------------------
-- Placement: reconcile helpers
-- --------------------------------------------------------------------------

-- Fast position-cache key. Using a local upvalue avoids repeated global lookups
-- and the inline string.format overhead in the BFS hot loop.
local function pos_key(x, y, z) return x .. "," .. y .. "," .. z end

-- Build a table mapping pos_key(x,y,z) → roomID for all rooms in the area
-- that have coordinates.  Much cheaper than calling getRoomsByPosition per BFS node.
local function build_pos_cache(areaID)
    local cache = {}
    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then return cache end
    for _, id in ipairs(rooms) do
        local x, y, z = getRoomCoordinates(id)
        if x ~= nil then
            cache[pos_key(x, y, z)] = id
        end
    end
    return cache
end

-- Return a seed room for reconcile: prefer the current/player room if it is
-- in areaID and has at least one linked exit; otherwise scan areaRooms for the
-- first room that has linked exits (a proxy for being well-connected).
local function find_best_seed(areaID)
    local function has_exits(id)
        local ex = getRoomExits(id)
        if type(ex) ~= "table" then return false end
        for _ in pairs(ex) do return true end
        return false
    end
    -- Prefer the live GMCP room.
    if type(map.room_info) == "table" and type(map.room_info.vnum) == "string" then
        local cur = getRoomIDbyHash(map.room_info.vnum)
        if type(cur) == "number" and cur > 0 and getRoomArea(cur) == areaID
            and has_exits(cur) then
            return cur
        end
    end
    -- Prefer mapper cursor room.
    local cur = type(getPlayerRoom) == "function" and getPlayerRoom() or nil
    if type(cur) == "number" and cur > 0 and getRoomArea(cur) == areaID
        and has_exits(cur) then
        return cur
    end
    -- Fall back to first room in the area that has linked exits.
    local areaRooms = getAreaRooms(areaID)
    if type(areaRooms) == "table" then
        for _, id in ipairs(areaRooms) do
            if has_exits(id) then return id end
        end
        -- Last resort: any room with coordinates.
        for _, id in ipairs(areaRooms) do
            local x = getRoomCoordinates(id)
            if x ~= nil then return id end
        end
    end
    return nil
end

-- --------------------------------------------------------------------------
-- Placement: reconcile
-- --------------------------------------------------------------------------

-- Move a set of already-mapped rooms so their coordinate offsets from
-- `anchorID` match the physical exit directions that connect them.
-- maxDepth limits how many BFS hops away from anchorID are examined.
-- Pass nil (or omit) for an unlimited full-area reconcile (e.g. 'map normalize').
-- Pass a small number (e.g. 5) for the per-move auto-reconcile so the BFS
-- stays local and doesn't traverse thousands of rooms on large maps.
-- externalVisited: optional shared table so callers can track visited rooms
-- across multiple subgraph seeds (used by 'map normalize all').
function _.reconcile_connected_rooms(anchorID, maxPasses, maxMoves, maxDepth, externalVisited)
    maxPasses = maxPasses or map.configs.reconcile_max_passes
    maxMoves  = maxMoves or map.configs.reconcile_max_moves

    if type(anchorID) ~= "number" or anchorID < 1 then return end
    local areaID = getRoomArea(anchorID)
    if not areaID then return end

    local ax, ay, az = getRoomCoordinates(anchorID)
    if ax == nil then return end

    local moved = 0
    for _pass = 1, maxPasses do
        local passMove = 0

        -- Pre-build position cache once per pass (much cheaper than calling
        -- getRoomsByPosition for every exit of every room during BFS).
        local posCache = build_pos_cache(areaID)

        -- BFS from anchor
        local queue    = { { id = anchorID, depth = 0 } }
        local qHead    = 1
        local visited  = { [anchorID] = true }
        if externalVisited then externalVisited[anchorID] = true end
        while qHead <= #queue do
            local entry   = queue[qHead]
            local current = entry.id
            local depth   = entry.depth
            qHead         = qHead + 1
            local exits   = getRoomExits(current)
            if type(exits) == "table" then
                local cx, cy, cz = getRoomCoordinates(current)
                if cx == nil then
                    -- skip; room has no coordinates
                else
                    for dir, targetID in pairs(exits) do
                        if type(targetID) == "string" then
                            targetID = tonumber(targetID)
                        end
                        if type(targetID) == "number" and targetID > 0 then
                            local targetAreaID = getRoomArea(targetID)
                            if targetAreaID == areaID and not visited[targetID] then
                                visited[targetID] = true
                                local nextDepth = depth + 1
                                local shift = _.get_shift_for_exit_key(dir)
                                if shift then
                                    local expectedX       = cx + shift[1]
                                    local expectedY       = cy + shift[2]
                                    local expectedZ       = cz + shift[3]

                                    local posKey          = pos_key(expectedX, expectedY, expectedZ)
                                    local occupantID      = posCache[posKey]
                                    local alreadyOccupied = occupantID ~= nil and occupantID ~= targetID

                                    if not alreadyOccupied then
                                        local tx, ty, tz = getRoomCoordinates(targetID)
                                        if tx ~= expectedX or ty ~= expectedY or tz ~= expectedZ then
                                            local forcedZ = _.get_forced_z_for_room(targetID)
                                            local finalZ  = (forcedZ ~= nil and shift[3] == 0) and forcedZ or expectedZ
                                            if tx ~= expectedX or ty ~= expectedY or tz ~= finalZ then
                                                -- Update cache: remove old position, add new.
                                                if tx ~= nil then
                                                    posCache[pos_key(tx, ty, tz)] = nil
                                                end
                                                posCache[pos_key(expectedX, expectedY, finalZ)] = targetID
                                                setRoomCoordinates(targetID, expectedX, expectedY, finalZ)
                                                passMove = passMove + 1
                                                moved    = moved + 1
                                                if moved >= maxMoves then return moved end
                                            end
                                        end
                                    end
                                end
                                if not maxDepth or nextDepth < maxDepth then
                                    table.insert(queue, { id = targetID, depth = nextDepth })
                                    if externalVisited then externalVisited[targetID] = true end
                                end
                            end
                        end
                    end
                end
            end
        end

        if passMove == 0 then break end
    end
    return moved
end

-- Flatten rooms that are connected only by cardinal horizontal exits and have
-- z-coordinates out of step with the anchor room.
function _.flatten_cardinal_connected_rooms(anchorID)
    if type(anchorID) ~= "number" or anchorID < 1 then return end
    local areaID = getRoomArea(anchorID)
    if not areaID then return end

    local _cx, _cy, az = getRoomCoordinates(anchorID)
    if az == nil then return end

    local queue   = { anchorID }
    local qHead   = 1
    local visited = { [anchorID] = true }
    while qHead <= #queue do
        local current = queue[qHead]
        qHead         = qHead + 1
        local exits   = getRoomExits(current)
        if type(exits) ~= "table" then
        else
            local cx, cy, cz = getRoomCoordinates(current)
            for dir, targetID in pairs(exits) do
                if type(targetID) == "string" then
                    targetID = tonumber(targetID)
                end
                if type(targetID) == "number" and targetID > 0 then
                    local shift = _.get_shift_for_exit_key(dir)
                    local targetAreaID = getRoomArea(targetID)
                    if shift and _.is_horizontal_shift(shift)
                        and targetAreaID == areaID
                        and not visited[targetID] then
                        visited[targetID] = true
                        local tx, ty, tz = getRoomCoordinates(targetID)
                        local forcedZ = _.get_forced_z_for_room(targetID)
                        local targetZ = forcedZ ~= nil and forcedZ or cz
                        if tz ~= targetZ then
                            setRoomCoordinates(targetID, tx, ty, targetZ)
                        end
                        table.insert(queue, targetID)
                    end
                end
            end
        end
    end
end

-- --------------------------------------------------------------------------
-- Public layout commands
-- --------------------------------------------------------------------------

function map.normalize_room_layout(maxPasses, maxMoves, allRooms, areaName)
    maxPasses = maxPasses or map.configs.reconcile_deep_max_passes
    maxMoves  = maxMoves or map.configs.reconcile_deep_max_moves

    local areaID
    if type(areaName) == "string" and areaName ~= "" then
        -- Resolve area by name (case-insensitive substring match).
        local lower = areaName:lower()
        local areas = getAreaTable()
        if type(areas) == "table" then
            for name, id in pairs(areas) do
                if type(name) == "string" and name:lower():find(lower, 1, true) then
                    areaID = id
                    break
                end
            end
        end
        if not areaID then
            echo("Cannot normalise: no area found matching '" .. areaName .. "'.\n")
            return
        end
    else
        -- When online, use the GMCP-confirmed current room. When offline, fall back
        -- to the mapper's last-known cursor position via getPlayerRoom().
        local roomID
        if type(map.room_info) == "table" and type(map.room_info.vnum) == "string" then
            roomID = getRoomIDbyHash(map.room_info.vnum)
        end
        if type(roomID) ~= "number" or roomID < 1 then
            roomID = type(getPlayerRoom) == "function" and getPlayerRoom() or nil
        end
        if type(roomID) ~= "number" or roomID < 1 then
            echo("Cannot normalise: current room is unknown.\n")
            return
        end
        areaID = getRoomArea(roomID)
        if not areaID then
            echo("Cannot normalise: current room has no area.\n")
            return
        end
    end

    local areaName_display = getAreaTableSwap and getAreaTableSwap()[areaID] or ("area #" .. areaID)
    local moved = 0
    if allRooms then
        echo("Normalising all subgraphs in '" .. areaName_display .. "'...\n")
        local areaRooms     = getAreaRooms(areaID)
        local globalVisited = {}
        local seedCount     = 0
        if type(areaRooms) == "table" then
            for _, seedID in ipairs(areaRooms) do
                if not globalVisited[seedID] then
                    local subMoved = _.reconcile_connected_rooms(seedID, maxPasses, maxMoves, nil, globalVisited)
                    _.flatten_cardinal_connected_rooms(seedID)
                    moved     = moved + (subMoved or 0)
                    seedCount = seedCount + 1
                end
            end
        end
        echo("Normalised " .. moved .. " room" .. (moved == 1 and "" or "s") ..
            " across " .. seedCount .. " subgraph" .. (seedCount == 1 and "" or "s") .. ".\n")
    else
        local seedID = find_best_seed(areaID)
        if not seedID then
            echo("Cannot normalise: no rooms with exits found in '" .. areaName_display .. "'.\n")
            return
        end
        echo("Normalising '" .. areaName_display .. "'...\n")
        moved = _.reconcile_connected_rooms(seedID, maxPasses, maxMoves)
        _.flatten_cardinal_connected_rooms(seedID)
        echo("Normalised " .. (moved or 0) .. " room" .. ((moved or 0) == 1 and "" or "s") .. ".\n")
    end
    updateMap()
end

function map.normalize_all_areas(maxPasses, maxMoves)
    maxPasses   = maxPasses or map.configs.reconcile_deep_max_passes
    maxMoves    = maxMoves or map.configs.reconcile_deep_max_moves

    local areas = getAreaTable()
    if type(areas) ~= "table" then
        echo("Cannot normalise: no areas found.\n")
        return
    end

    local totalMoved = 0
    local areaCount  = 0
    local areaNames  = {}
    for name, _ in pairs(areas) do areaNames[#areaNames + 1] = name end
    table.sort(areaNames)

    for _, name in ipairs(areaNames) do
        local id = areas[name]
        local areaRooms = getAreaRooms(id)
        if type(areaRooms) == "table" and #areaRooms > 0 then
            local globalVisited = {}
            for _, seedID in ipairs(areaRooms) do
                if not globalVisited[seedID] then
                    local subMoved = _.reconcile_connected_rooms(seedID, maxPasses, maxMoves, nil, globalVisited)
                    _.flatten_cardinal_connected_rooms(seedID)
                    totalMoved = totalMoved + (subMoved or 0)
                end
            end
            areaCount = areaCount + 1
        end
    end

    updateMap()
    echo("Normalised " .. totalMoved .. " room" .. (totalMoved == 1 and "" or "s") ..
        " across " .. areaCount .. " area" .. (areaCount == 1 and "" or "s") .. ".\n")
end

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

    -- Determine whether the seed room is underground or elevated so we know the
    -- base z-level for each classification (surface vs underground vs elevated).
    local seedUG        = _.classify_room_underground(seedID, false)
    local seedEL        = _.classify_room_elevated(seedID)
    local surfaceZ      = (seedUG and (sz + 1)) or (seedEL and (sz - 1)) or sz
    local undergroundZ  = surfaceZ - 1
    local elevatedZ     = surfaceZ + 1

    -- FIFO queue: each entry carries position, underground, and elevated flags for z-separation.
    local queue         = { { id = seedID, x = sx, y = sy, z = sz, underground = seedUG, elevated = seedEL } }
    local qHead         = 1
    local visited       = { [seedID] = true }
    local occupied      = { [pos_key(sx, sy, sz)] = seedID }
    local movedCount    = 0
    local nudgeCount    = 0
    local levelCount    = 0
    local separateCount = 0

    -- Build a reverse lookup: roomID → { x, y, z } for the post-BFS separation pass.
    local roomPositions = { [seedID] = { x = sx, y = sy, z = sz } }
    -- Track parent shift for each room so the separation pass knows the axis to extend along.
    local roomShifts    = {}
    -- Track BFS parent so the separation pass can shift entire subtrees.
    local roomParents   = {}

    while qHead <= #queue do
        local entry = queue[qHead]
        qHead = qHead + 1
        local exits = getRoomExits(entry.id)

        if type(exits) == "table" then
            for dir, targetID in _.sorted_exit_pairs(exits) do
                if type(targetID) == "string" then
                    targetID = tonumber(targetID)
                end

                if type(targetID) == "number" and targetID > 0 and not visited[targetID] then
                    visited[targetID]  = true

                    local shift        = _.get_shift_for_exit_key(dir)
                    local targetAreaID = getRoomArea(targetID)

                    if shift and targetAreaID == areaID then
                        local tx = entry.x + shift[1]
                        local ty = entry.y + shift[2]
                        local tz = entry.z + shift[3]

                        -- Auto-detect underground rooms and place them on a
                        -- separate z-level so they don't visually overlap
                        -- with surface rooms in the mapper.
                        local targetUG = _.classify_room_underground(targetID, entry.underground)
                        local targetEL = _.classify_room_elevated(targetID)
                        if not entry.underground and targetUG then
                            -- Transition surface → underground
                            tz = undergroundZ
                            levelCount = levelCount + 1
                        elseif entry.underground and not targetUG then
                            -- Transition underground → surface
                            tz = surfaceZ
                            levelCount = levelCount + 1
                        elseif not entry.elevated and targetEL and not targetUG then
                            -- Transition surface → elevated (e.g. "Stone wall")
                            tz = elevatedZ
                            setRoomUserData(targetID, "elevationAdjustment", tostring(elevatedZ - surfaceZ))
                            levelCount = levelCount + 1
                        elseif entry.elevated and not targetEL and not targetUG then
                            -- Transition elevated → surface
                            tz = surfaceZ
                            levelCount = levelCount + 1
                        end

                        -- Collision avoidance: if the ideal position is already
                        -- taken by an earlier BFS room, nudge to the nearest
                        -- free spot so rooms don't stack on top of each other.
                        local posKey = pos_key(tx, ty, tz)
                        if occupied[posKey] then
                            tx, ty, tz = _.find_nearest_unoccupied(occupied, tx, ty, tz, shift)
                            posKey = pos_key(tx, ty, tz)
                            nudgeCount = nudgeCount + 1
                        end

                        occupied[posKey]        = targetID
                        roomPositions[targetID] = { x = tx, y = ty, z = tz }
                        roomShifts[targetID]    = shift
                        roomParents[targetID]   = entry.id

                        local cx, cy, cz        = getRoomCoordinates(targetID)
                        if cx ~= tx or cy ~= ty or cz ~= tz then
                            setRoomCoordinates(targetID, tx, ty, tz)
                            movedCount = movedCount + 1
                        end
                        table.insert(queue,
                            { id = targetID, x = tx, y = ty, z = tz, underground = targetUG, elevated = targetEL })
                    end
                end
            end
        end
    end

    -- Post-BFS separation pass: now that ALL rooms are placed, check each room
    -- that arrived via a pure cardinal exit.  If its perpendicular neighbours
    -- are unconnected rooms (i.e. it visually blends into an unrelated line),
    -- shift its entire BFS subtree further along the exit direction to create
    -- a visible gap.  Moving the whole subtree keeps relative positions intact.

    -- Build children lookup from parent tracking.
    local bfsChildren = {}
    for childID, parentID in pairs(roomParents) do
        if not bfsChildren[parentID] then bfsChildren[parentID] = {} end
        bfsChildren[parentID][#bfsChildren[parentID] + 1] = childID
    end

    -- Collect all BFS descendants of a room (inclusive).
    local function collectSubtree(rootID)
        local subtree = { rootID }
        local stack   = { rootID }
        while #stack > 0 do
            local cur = table.remove(stack)
            if bfsChildren[cur] then
                for _, cid in ipairs(bfsChildren[cur]) do
                    subtree[#subtree + 1] = cid
                    stack[#stack + 1]     = cid
                end
            end
        end
        return subtree
    end

    -- Helper: are two rooms connected by an exit in either direction?
    local function rooms_connected(idA, idB)
        local exA = getRoomExits(idA)
        if type(exA) == "table" then
            for _, eid in pairs(exA) do
                if tonumber(eid) == idB then return true end
            end
        end
        local exB = getRoomExits(idB)
        if type(exB) == "table" then
            for _, eid in pairs(exB) do
                if tonumber(eid) == idA then return true end
            end
        end
        return false
    end

    local shifted = {} -- rooms already moved as part of a subtree

    for roomID, pos in pairs(roomPositions) do
        local shift = roomShifts[roomID]
        -- Only process rooms that arrived via a pure cardinal horizontal exit
        if shift and not shifted[roomID]
            and shift[3] == 0
            and ((shift[1] == 0) ~= (shift[2] == 0)) then
            local tx, ty, tz = pos.x, pos.y, pos.z
            local perpPositions
            if shift[1] ~= 0 and shift[2] == 0 then
                perpPositions = { { tx, ty + 1, tz }, { tx, ty - 1, tz } }
            else
                perpPositions = { { tx + 1, ty, tz }, { tx - 1, ty, tz } }
            end

            local needsSeparation = false
            for _, pp in ipairs(perpPositions) do
                local perpKey    = pos_key(pp[1], pp[2], pp[3])
                local perpRoomID = occupied[perpKey]
                if perpRoomID and not rooms_connected(roomID, perpRoomID) then
                    needsSeparation = true
                    break
                end
            end

            if needsSeparation then
                local subtree    = collectSubtree(roomID)
                local subtreeSet = {}
                for _, rid in ipairs(subtree) do subtreeSet[rid] = true end

                -- Probe increasing distances along the arrival direction until
                -- the entire subtree fits without colliding with non-subtree rooms.
                local dx, dy  = shift[1], shift[2]
                local maxDist = 5
                local found   = false
                local dist    = 1
                while dist <= maxDist do
                    local ok = true
                    for _, rid in ipairs(subtree) do
                        local rp = roomPositions[rid]
                        local nk = pos_key(rp.x + dx * dist, rp.y + dy * dist, rp.z)
                        local occupant = occupied[nk]
                        if occupant and not subtreeSet[occupant] then
                            ok = false
                            break
                        end
                    end
                    if ok then
                        found = true; break
                    end
                    dist = dist + 1
                end

                if found then
                    -- Remove old positions from occupied.
                    for _, rid in ipairs(subtree) do
                        local rp       = roomPositions[rid]
                        local oKey     = pos_key(rp.x, rp.y, rp.z)
                        occupied[oKey] = nil
                    end
                    -- Place at new positions.
                    for _, rid in ipairs(subtree) do
                        local rp = roomPositions[rid]
                        rp.x = rp.x + dx * dist
                        rp.y = rp.y + dy * dist
                        local nKey = pos_key(rp.x, rp.y, rp.z)
                        occupied[nKey] = rid
                        setRoomCoordinates(rid, rp.x, rp.y, rp.z)
                        shifted[rid] = true
                        movedCount = movedCount + 1
                    end
                    separateCount = separateCount + #subtree
                end
            end
        end
    end

    updateMap()
    local msg = "Topology recalculation repositioned " .. movedCount ..
        " room" .. (movedCount == 1 and "" or "s")
    local details = {}
    if nudgeCount > 0 then
        details[#details + 1] = nudgeCount .. " nudged to avoid overlap"
    end
    if levelCount > 0 then
        details[#details + 1] = levelCount .. " moved to separate z-level"
    end
    if separateCount > 0 then
        details[#details + 1] = separateCount .. " extended for visual separation"
    end
    if #details > 0 then
        msg = msg .. " (" .. table.concat(details, ", ") .. ")"
    end
    echo(msg .. ".\n")
end
