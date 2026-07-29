-- Mapping Script — Layout
-- Functions that determine and adjust room coordinates:
--   create_neighbors_for_current_room, reconcile_connected_rooms,
--   flatten_cardinal_connected_rooms, map.normalize_room_layout,
--   map.recalculate_room_layout.

map     = map or {}
map._   = map._ or {}
local _ = map._

-- Safe wrappers for helpers that live in Helpers.lua.  These guard against
-- the (rare) case where Layout.lua executes a queued GMCP event before the
-- newer Helpers chunk has been loaded into the same namespace (e.g. after a
-- partial package reload), so we never bomb out with "attempt to call a nil
-- value" on _.is_room_locked / _.current_player_room_id.
local function safe_is_room_locked(rid)
    local fn = _.is_room_locked
    if type(fn) == "function" then
        return fn(rid)
    end
    if type(rid) ~= "number" or rid < 1 then return false end
    return getRoomUserData(rid, "locked") == "1"
end

local function safe_current_player_room_id()
    local fn = _.current_player_room_id
    if type(fn) == "function" then
        return fn()
    end
    if type(map.room_info) == "table" and type(map.room_info.vnum) == "string" then
        local id = getRoomIDbyHash(map.room_info.vnum)
        if type(id) == "number" and id > 0 then return id end
    end
    return nil
end

-- Run a function while treating only anchorRoomID as "locked".
-- Used by both map normalize and map recalculate so the repair BFS can
-- spread freely from the room the process started from — no other room's
-- lock flag is honoured for the duration of fn, even if the user pinned it.
local function with_single_locked_anchor(anchorRoomID, fn)
    if type(fn) ~= "function" then return nil end
    local previous = _.is_room_locked
    _.is_room_locked = function(rid)
        return type(rid) == "number" and rid == anchorRoomID
    end

    local ok, a, b, c, d = xpcall(fn, debug.traceback)
    _.is_room_locked = previous
    if not ok then error(a) end
    return a, b, c, d
end

-- --------------------------------------------------------------------------
-- Placement: neighbours
-- --------------------------------------------------------------------------

function _.create_neighbors_for_current_room(roomID, posCache)
    local info = map.room_info
    if type(info.exits) ~= "table" then return end
    if type(roomID) ~= "number" or roomID < 1 then return end

    local areaID = getRoomArea(roomID)
    if not areaID or areaID < 1 then return end

    local cx, cy, cz = getRoomCoordinates(roomID)
    if cx == nil then return end

    -- Build the position cache here if the caller didn't supply one.  Sharing
    -- it with handle_move/reconcile avoids repeated O(area) walks per event.
    -- For large areas skip the O(N) full build; sub-functions will fall back
    -- to direct getRoomsByPosition() calls on cache misses.
    if posCache == nil or posCache._areaID ~= areaID then
        if type(_.is_large_area) == "function" and _.is_large_area(areaID) then
            posCache = { _areaID = areaID, _rooms = {}, _large_area = true }
        else
            posCache = _.build_pos_cache(areaID)
        end
    end

    local forcedZ          = _.get_forced_z_for_room(roomID)
    local createdCount     = 0
    -- Track only the positions touched this event so the backstop dedup
    -- doesn't have to walk the entire area posCache on every player step.
    local touchedPositions = {}

    for dir, targetVnum in pairs(info.exits) do
        if type(targetVnum) ~= "string" then
            -- skip bad values
        else
            local shift    = _.get_shift_for_exit_key(dir)

            local targetID = getRoomIDbyHash(targetVnum)
            local created  = false

            -- Guard against stale hash bindings that survive deleteRoom:
            -- Mudlet retains the hash→ID entry even after the room is deleted,
            -- so getRoomIDbyHash can return a ghost ID whose area is invalid.
            -- Treat such IDs as missing so the candidate-search runs.
            if type(targetID) == "number" and targetID > 0 then
                local existingArea = getRoomArea(targetID)
                local tx, ty, tz = getRoomCoordinates(targetID)
                local targetName = getRoomName(targetID)
                local hasName = type(targetName) == "string" and targetName ~= ""
                local hasCoords = tx ~= nil and ty ~= nil and tz ~= nil
                if not existingArea or existingArea < 1 or (not hasCoords and not hasName) then
                    pcall(setRoomIDbyHash, targetID, "")
                    targetID = -1
                end
            end

            -- Detect "duplicate physical room": the hash points at a
            -- placeholder but a real (non-placeholder) room already sits at
            -- the expected adjacent position.  This happens when a previous
            -- visit adopted/rebound the real room under a different vnum and
            -- GMCP later serves the original placeholder vnum again.  Merge
            -- the placeholder into the real room so we don't keep stacking
            -- duplicates on every refresh.
            if type(targetID) == "number" and targetID > 0
                and shift
                and type(_.is_placeholder) == "function"
                and _.is_placeholder(targetID) then
                local tx = cx + shift[1]
                local ty = cy + shift[2]
                local tz = cz + shift[3]
                -- Do NOT override tz with forcedZ here: a horizontal neighbour
                -- must share the current room's z-plane (cz). forcedZ is a
                -- normalisation hint for whole-component passes, not for
                -- individual room placement (see Data.lua forced_z_by_terrain_name).
                local near = _.pos_cache_get(posCache, tx, ty, tz)
                -- Large-area sentinel: cache has no coord mapping, so fall back
                -- to Mudlet's native positional look-up.
                if near == nil and type(getRoomsByPosition) == "function" then
                    near = getRoomsByPosition(areaID, tx, ty, tz)
                end
                local realAtPos = nil
                local function is_live_real(rid)
                    if type(rid) ~= "number" or rid < 1 then return false end
                    if rid == targetID then return false end
                    local a = getRoomArea(rid)
                    if type(a) ~= "number" or a < 1 then return false end
                    -- Never absorb a locked room (manually pinned by the user)
                    -- as a "merge target" — its identity must be preserved.
                    if safe_is_room_locked(rid) then return false end
                    -- Never absorb a room that already has its own hash
                    -- binding; rebinding its hash to a neighbor's vnum would
                    -- clobber its identity and detach the original vnum.
                    if type(getRoomHashByID) == "function" then
                        local h = getRoomHashByID(rid)
                        if type(h) == "string" and h ~= "" then return false end
                    end
                    return not _.is_placeholder(rid)
                end
                if type(near) == "table" then
                    for _, rid in ipairs(near) do
                        if is_live_real(rid) then
                            realAtPos = rid
                            break
                        end
                    end
                end
                if realAtPos then
                    local dx, dy, dz = getRoomCoordinates(targetID)
                    pcall(setRoomIDbyHash, targetID, "")
                    if _.delete_room(targetID) then
                        _.pos_cache_drop(posCache, dx, dy, dz, targetID)
                    end
                    _.bind_room_hash(realAtPos, targetVnum)
                    _.mark_autowalk_dirty()
                    if type(_.debug_echo) == "function" then
                        _.debug_echo("Merged placeholder " .. targetID
                            .. " into real room " .. realAtPos
                            .. " for vnum " .. targetVnum .. " (dir " .. dir .. ")\n")
                    end
                    targetID = realAtPos
                end
            end

            if targetID < 1 then
                -- Before creating a new placeholder, look for an existing room
                -- that already covers this exit so we never stack two rooms at
                -- the same map position.  Two sources are tried in order:
                --   A) the room Mudlet already has wired in this direction
                --      (set by a previous visit or map normalize)
                --   B) whichever room occupies the expected adjacent position
                -- If the candidate has NO hash we adopt it fully (bind it to
                -- the incoming GMCP vnum).  If it already has its own hash we
                -- leave that binding alone and simply reuse the room as the
                -- exit target — this prevents stacking without corrupting the
                -- existing identity of a separately-mapped room.
                local candidateID = nil

                local function is_live(rid)
                    if type(rid) ~= "number" or rid < 1 then return false end
                    local a = getRoomArea(rid)
                    return type(a) == "number" and a > 0
                end

                -- Source A: wired exit
                if type(_.get_room_exit_target) == "function" then
                    local w = _.get_room_exit_target(roomID, dir)
                    if is_live(w) then
                        candidateID = w
                    end
                end

                -- Source B: positional occupant at the expected coords.
                -- Mudlet's deleteRoom leaves stale position bindings behind,
                -- so we must filter out ghost IDs whose area is no longer
                -- valid — otherwise we "reuse" a deleted room and the
                -- placement block below resurrects it on every refresh.
                if not candidateID and shift then
                    local tx = cx + shift[1]
                    local ty = cy + shift[2]
                    local tz = cz + shift[3]
                    -- Do NOT override tz with forcedZ: candidate search must look
                    -- at the actual adjacent position on the current z-plane.
                    local near = _.pos_cache_get(posCache, tx, ty, tz)
                    -- Large-area sentinel: fall back to native positional look-up.
                    if near == nil and type(getRoomsByPosition) == "function" then
                        near = getRoomsByPosition(areaID, tx, ty, tz)
                    end
                    if type(near) == "table" then
                        for _, rid in ipairs(near) do
                            if is_live(rid) then
                                candidateID = rid
                                break
                            end
                        end
                    end
                end

                if type(candidateID) == "number" and candidateID > 0 then
                    local cHash = type(getRoomHashByID) == "function"
                        and getRoomHashByID(candidateID) or nil
                    local candidateIsPlaceholder = type(_.is_placeholder) == "function"
                        and _.is_placeholder(candidateID)
                    if cHash == nil or cHash == "" or candidateIsPlaceholder then
                        -- Hashless room OR placeholder: adopt fully — bind this
                        -- GMCP vnum to the existing room to avoid stacking.
                        if type(cHash) == "string" and cHash ~= "" and cHash ~= targetVnum then
                            pcall(setRoomIDbyHash, candidateID, "")
                        end
                        _.bind_room_hash(candidateID, targetVnum)
                        _.mark_autowalk_dirty()
                        _.debug_echo("Adopted existing room " .. candidateID
                            .. " for vnum " .. targetVnum .. " (dir " .. dir .. ")\n")
                    else
                        -- Room already has its own identity; just reuse it to
                        -- avoid stacking.  Don't touch its hash.
                        _.debug_echo("Reusing " .. candidateID
                            .. " (existing hash) to avoid stacking for "
                            .. targetVnum .. " (dir " .. dir .. ")\n")
                    end
                    targetID = candidateID
                end
            end

            if targetID < 1 then
                targetID = createRoomID()
                _.add_room(targetID)
                -- The index updates take areaID explicitly because the room
                -- does not have an area yet: the placement block below is what
                -- calls set_room_area for it.
                _.bind_room_hash(targetID, targetVnum, areaID)
                created = true
                createdCount = createdCount + 1
                _.set_room_name(targetID, targetVnum, areaID)
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

                    -- Do NOT override tz with forcedZ here. A newly created
                    -- neighbour must sit on the current room's z-plane (cz).
                    -- Snapping to forcedZ (e.g. z=0 for "dense forest") is what
                    -- caused room 310221 to be placed 33 levels below its siblings.
                    -- forcedZ is a normalisation-pass hint only (see Data.lua).

                    local skipStretch = _.should_skip_stretch_for_area(areaID)
                    _.move_room_to_expected_position(targetID, targetVnum, areaID,
                        { tx, ty, tz }, shift, skipStretch, posCache)
                else
                    _.set_room_area(targetID, areaID)
                end
            end

            -- Wire up exits.
            if shift then
                local x2, y2, z2 = getRoomCoordinates(targetID)
                if x2 == nil then
                    setRoomCoordinates(targetID, cx + shift[1], cy + shift[2], cz + shift[3])
                    _.pos_cache_add(posCache,
                        cx + shift[1], cy + shift[2], cz + shift[3], targetID)
                end
            end

            -- Lowest-ID-wins dedup pass.  Catches every stacking case (ghost
            -- IDs resurrected by setRoomCoordinates, candidate-search misses,
            -- pre-existing duplicates, etc.) by collapsing all live rooms at
            -- the target's coords down to the single lowest-ID survivor.
            -- Higher-ID duplicates are deleted; if the survivor is a bare
            -- placeholder we promote it by copying name/env/symbol from the
            -- displaced real room first, and we transfer the GMCP hash binding
            -- so the room's identity is preserved.
            do
                local fx, fy, fz = getRoomCoordinates(targetID)
                if fx ~= nil then
                    -- Record this position so the backstop only scans touched spots.
                    touchedPositions[_.pos_cache_key(fx, fy, fz)] = true
                    local hits = _.pos_cache_get(posCache, fx, fy, fz)
                    -- Large-area sentinel: fall back to native positional look-up.
                    if hits == nil and type(getRoomsByPosition) == "function" then
                        hits = getRoomsByPosition(areaID, fx, fy, fz)
                    end
                    local liveIDs = {}
                    local function consider(rid)
                        if type(rid) == "number" and rid > 0 then
                            local a = getRoomArea(rid)
                            if type(a) == "number" and a > 0 then
                                liveIDs[#liveIDs + 1] = rid
                            end
                        end
                    end
                    if type(hits) == "table" then
                        for _, rid in ipairs(hits) do consider(rid) end
                    end
                    if #liveIDs > 1 then
                        -- Survivor preference: locked rooms first, then the
                        -- player's current room, then lowest ID.  Ensures
                        -- manually-pinned rooms and the player's anchor are
                        -- never demoted/deleted by the dedup pass.
                        local playerID = safe_current_player_room_id()
                        table.sort(liveIDs, function(a, b)
                            local la, lb = safe_is_room_locked(a), safe_is_room_locked(b)
                            if la ~= lb then return la end
                            local pa, pb = (a == playerID), (b == playerID)
                            if pa ~= pb then return pa end
                            return a < b
                        end)
                        local keep = liveIDs[1]
                        local has_is_placeholder = type(_.is_placeholder) == "function"
                        for i = 2, #liveIDs do
                            local dup = liveIDs[i]
                            if safe_is_room_locked(dup) then
                                if type(_.debug_echo) == "function" then
                                    _.debug_echo("Dedup: refused to delete locked room "
                                        .. dup .. " (kept " .. keep .. ")\n")
                                end
                            else
                                -- Promote: if survivor is a placeholder and the
                                -- duplicate is a real room, copy its visible attrs.
                                if has_is_placeholder
                                    and _.is_placeholder(keep) and not _.is_placeholder(dup) then
                                    local n = getRoomName(dup)
                                    if type(n) == "string" and n ~= "" then _.set_room_name(keep, n) end
                                    local env = getRoomEnv(dup)
                                    if type(env) == "number" and env > 0 then
                                        setRoomEnv(keep, env)
                                    end
                                    if type(getRoomChar) == "function"
                                        and type(setRoomChar) == "function" then
                                        local sym = getRoomChar(dup)
                                        if type(sym) == "string" and sym ~= "" then
                                            pcall(setRoomChar, keep, sym)
                                        end
                                    end
                                end
                                -- Transfer hash binding to survivor if it has none.
                                if type(getRoomHashByID) == "function" then
                                    local dupHash  = getRoomHashByID(dup)
                                    local keepHash = getRoomHashByID(keep)
                                    local keepIsPlaceholder = has_is_placeholder and _.is_placeholder(keep)
                                    if type(dupHash) == "string" and dupHash ~= "" then
                                        if ((keepHash == nil or keepHash == "") or keepIsPlaceholder) then
                                            if type(keepHash) == "string" and keepHash ~= ""
                                                and keepHash ~= dupHash then
                                                pcall(setRoomIDbyHash, keep, "")
                                            end
                                            pcall(setRoomIDbyHash, dup, "")
                                            _.bind_room_hash(keep, dupHash)
                                        else
                                            pcall(setRoomIDbyHash, dup, "")
                                        end
                                    end
                                end
                                if _.delete_room(dup) then
                                    _.pos_cache_drop(posCache, fx, fy, fz, dup)
                                end
                                if type(_.debug_echo) == "function" then
                                    _.debug_echo("Dedup: deleted duplicate room " .. dup
                                        .. " (kept " .. keep .. ") at ("
                                        .. fx .. "," .. fy .. "," .. fz .. ")\n")
                                end
                            end
                        end
                        -- Ensure the incoming GMCP vnum points at the survivor.
                        local keepHash = type(getRoomHashByID) == "function"
                            and getRoomHashByID(keep) or nil
                        local keepIsPlaceholder = has_is_placeholder and _.is_placeholder(keep)
                        if keepHash == nil or keepHash == ""
                            or (keepIsPlaceholder and keepHash ~= targetVnum) then
                            if type(keepHash) == "string" and keepHash ~= "" and keepHash ~= targetVnum then
                                pcall(setRoomIDbyHash, keep, "")
                            end
                            _.bind_room_hash(keep, targetVnum)
                        end
                        targetID = keep
                        _.mark_autowalk_dirty()
                    end
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

    -- Final positional dedup backstop.  Only checks positions that were
    -- actually touched this event (at most one per GMCP exit direction),
    -- instead of scanning the entire area posCache.  This keeps the cost
    -- O(exits) ≈ O(12) rather than O(all rooms in area) per player step.
    do
        local cachedMyExits = nil
        local function get_my_exits()
            if cachedMyExits == nil then cachedMyExits = getRoomExits(roomID) or false end
            return cachedMyExits or nil
        end
        for key in pairs(touchedPositions) do
            local list = posCache[key]
            if type(list) == "table" and #list > 1 then
                -- Survivor preference: locked > player current room > lowest ID.
                local playerID = safe_current_player_room_id()
                table.sort(list, function(a, b)
                    local la, lb = safe_is_room_locked(a), safe_is_room_locked(b)
                    if la ~= lb then return la end
                    local pa, pb = (a == playerID), (b == playerID)
                    if pa ~= pb then return pa end
                    return a < b
                end)
                local keep = list[1]
                local has_is_placeholder = type(_.is_placeholder) == "function"
                local i = 2
                while i <= #list do
                    local dup = list[i]
                    if safe_is_room_locked(dup) then
                        if type(_.debug_echo) == "function" then
                            _.debug_echo("Final dedup: refused to delete locked room "
                                .. dup .. " (kept " .. keep .. ")\n")
                        end
                        i = i + 1
                    else
                        -- Promote survivor with real-room attrs if needed.
                        if has_is_placeholder
                            and _.is_placeholder(keep) and not _.is_placeholder(dup) then
                            local n = getRoomName(dup)
                            if type(n) == "string" and n ~= "" then _.set_room_name(keep, n) end
                            local env = getRoomEnv(dup)
                            if type(env) == "number" and env > 0 then
                                setRoomEnv(keep, env)
                            end
                            if type(getRoomChar) == "function"
                                and type(setRoomChar) == "function" then
                                local sym = getRoomChar(dup)
                                if type(sym) == "string" and sym ~= "" then
                                    pcall(setRoomChar, keep, sym)
                                end
                            end
                        end
                        -- Transfer hash binding to survivor if it lacks one.
                        if type(getRoomHashByID) == "function" then
                            local dupHash  = getRoomHashByID(dup)
                            local keepHash = getRoomHashByID(keep)
                            local keepIsPlaceholder = has_is_placeholder and _.is_placeholder(keep)
                            if type(dupHash) == "string" and dupHash ~= "" then
                                if ((keepHash == nil or keepHash == "") or keepIsPlaceholder) then
                                    if type(keepHash) == "string" and keepHash ~= ""
                                        and keepHash ~= dupHash then
                                        pcall(setRoomIDbyHash, keep, "")
                                    end
                                    pcall(setRoomIDbyHash, dup, "")
                                    _.bind_room_hash(keep, dupHash)
                                else
                                    pcall(setRoomIDbyHash, dup, "")
                                end
                            end
                        end
                        -- Re-wire any exits from the current room that
                        -- pointed at the duplicate to point at the survivor.
                        local myExits = get_my_exits()
                        if type(myExits) == "table" then
                            local has_norm = type(_.normalize_exit_direction) == "function"
                            for d, tgt in pairs(myExits) do
                                if type(tgt) == "string" then tgt = tonumber(tgt) end
                                if tgt == dup then
                                    local nd = has_norm and _.normalize_exit_direction(d) or d
                                    if type(nd) == "string" then
                                        pcall(setExit, roomID, keep, nd)
                                    end
                                end
                            end
                        end
                        _.delete_room(dup)
                        table.remove(list, i)
                        if type(_.debug_echo) == "function" then
                            _.debug_echo("Final dedup: deleted duplicate room "
                                .. dup .. " (kept " .. keep .. ")\n")
                        end
                    end -- not locked
                end
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
function _.reconcile_connected_rooms(anchorID, maxPasses, maxMoves, maxDepth, externalVisited, externalPosCache)
    maxPasses = maxPasses or map.configs.reconcile_max_passes
    maxMoves  = maxMoves or map.configs.reconcile_max_moves

    if type(anchorID) ~= "number" or anchorID < 1 then return end
    local areaID = getRoomArea(anchorID)
    if not areaID then return end

    local ax, ay, az = getRoomCoordinates(anchorID)
    if ax == nil then return end

    -- If the caller supplied a cache for this area, reuse it across passes
    -- (and feed our own mutations back into it for downstream callers).
    -- Otherwise build a fresh one and rebuild between passes only when
    -- forced — passes converge in-place so we can keep mutating the cache.
    local sharedCache = (externalPosCache and externalPosCache._areaID == areaID) and externalPosCache or nil

    local moved = 0
    for _pass = 1, maxPasses do
        local passMove = 0

        local posCache = sharedCache or _.build_pos_cache(areaID)

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
                    -- Canonical (cardinals-first) order, not raw pairs(): when a
                    -- room graph has a genuine cyclic/conflicting-delta bug, which
                    -- neighbour "wins" a contested cell depends on visit order.
                    -- pairs() order over Mudlet's exit table is not guaranteed
                    -- stable across calls, which made reconcile (and therefore
                    -- map normalize) resolve such conflicts differently from run
                    -- to run. map.recalculate_room_layout already uses this same
                    -- canonical order for exactly this reason.
                    for dir, targetID in _.sorted_exit_pairs(exits) do
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

                                    local occupants       = _.pos_cache_get(posCache,
                                        expectedX, expectedY, expectedZ)
                                    local alreadyOccupied = false
                                    if type(occupants) == "table" then
                                        for _, oid in ipairs(occupants) do
                                            if oid ~= targetID then
                                                alreadyOccupied = true
                                                break
                                            end
                                        end
                                    end

                                    if not alreadyOccupied and not safe_is_room_locked(targetID) then
                                        local tx, ty, tz = getRoomCoordinates(targetID)
                                        if tx ~= expectedX or ty ~= expectedY or tz ~= expectedZ then
                                            -- Use expectedZ directly: it already reflects the anchor's
                                            -- actual z-plane. Overriding with forcedZ was what snapped
                                            -- terrain-labelled rooms to z=0 even when the whole cluster
                                            -- lives at a different z (e.g. forest grid at z=33).
                                            if tx ~= expectedX or ty ~= expectedY or tz ~= expectedZ then
                                                setRoomCoordinates(targetID, expectedX, expectedY, expectedZ)
                                                _.pos_cache_move(posCache, tx, ty, tz,
                                                    expectedX, expectedY, expectedZ, targetID)
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

    local queue       = { anchorID }
    local qHead       = 1
    local visited     = { [anchorID] = true }
    local MAX_FLATTEN = 200000 -- safety cap; prevents freeze on very large connected areas
    while qHead <= #queue do
        if qHead > MAX_FLATTEN then
            break
        end
        local current = queue[qHead]
        qHead         = qHead + 1
        local exits   = getRoomExits(current)
        if type(exits) ~= "table" then
        else
            local cx, cy, cz = getRoomCoordinates(current)
            -- Canonical order (see the matching comment in reconcile_connected_rooms)
            -- so which parent's z a room inherits doesn't depend on Mudlet's
            -- exit-table iteration order when the same room is reachable two ways.
            for dir, targetID in _.sorted_exit_pairs(exits) do
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
                        -- Flatten to the anchor's actual z (cz), not forcedZ.
                        -- forcedZ is a normalisation hint for whole-component passes;
                        -- using it here snaps terrain-labelled rooms to z=0 even when
                        -- the connected cluster lives at a different z level.
                        if tz ~= cz and not safe_is_room_locked(targetID) then
                            setRoomCoordinates(targetID, tx, ty, cz)
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

-- Shared bucketed report emitted at the end of normalize and recalculate.
-- selfLoopsRemoved: integer from _.strip_self_loop_exits
-- movedCount:       rooms repositioned by BFS
-- snapResult:       table returned by _.snap_vertical_pair
-- audit:            table returned by _.audit_layout_anomalies
-- dedupeResult: table returned by map.dedupe_area_by_hash (may be nil)
-- anchorResult:  table returned by _.apply_anchor_translation (may be nil)
local function emit_repair_report(selfLoopsRemoved, movedCount, snapResult, audit, dedupeResult, anchorResult, overlapResult)
    local parts = {}
    if selfLoopsRemoved > 0 then
        parts[#parts + 1] = selfLoopsRemoved
            .. " self-loop exit" .. (selfLoopsRemoved == 1 and "" or "s") .. " removed"
    end
    if dedupeResult and dedupeResult.removed > 0 then
        parts[#parts + 1] = dedupeResult.removed
            .. " duplicate room" .. (dedupeResult.removed == 1 and "" or "s") .. " merged"
    end
    if dedupeResult and dedupeResult.skipped > 0 then
        parts[#parts + 1] = dedupeResult.skipped
            .. " duplicate group" .. (dedupeResult.skipped == 1 and "" or "s")
            .. " skipped (all locked)"
    end
    if movedCount > 0 then
        parts[#parts + 1] = movedCount
            .. " room" .. (movedCount == 1 and "" or "s") .. " repositioned"
    end
    if snapResult.snapped > 0 then
        parts[#parts + 1] = snapResult.snapped
            .. " vertical pair" .. (snapResult.snapped == 1 and "" or "s") .. " snapped"
    end
    if snapResult.blocked > 0 then
        parts[#parts + 1] = snapResult.blocked
            .. " vertical snap" .. (snapResult.blocked == 1 and "" or "s") .. " blocked by occupant"
    end
    if snapResult.shared_target_bug > 0 then
        parts[#parts + 1] = snapResult.shared_target_bug
            .. " shared-target bug" .. (snapResult.shared_target_bug == 1 and "" or "s")
            .. " (in-area duplicate exit — data issue)"
    end
    if anchorResult and anchorResult.translated > 0 then
        parts[#parts + 1] = anchorResult.translated
            .. " sub-graph" .. (anchorResult.translated == 1 and "" or "s")
            .. " aligned to game coords"
    end
    if anchorResult and anchorResult.unanchored_subgraphs > 0 then
        parts[#parts + 1] = anchorResult.unanchored_subgraphs
            .. " sub-graph" .. (anchorResult.unanchored_subgraphs == 1 and "" or "s")
            .. " unanchored (no coord data)"
    end
    if anchorResult and anchorResult.anchor_disagreements > 0 then
        parts[#parts + 1] = anchorResult.anchor_disagreements
            .. " anchor disagreement" .. (anchorResult.anchor_disagreements == 1 and "" or "s")
            .. " (picked lowest-id anchor)"
    end
    if anchorResult and anchorResult.skipped > 0 then
        parts[#parts + 1] = anchorResult.skipped
            .. " sub-graph" .. (anchorResult.skipped == 1 and "" or "s")
            .. " not translated (locked room or collision)"
    end
    if overlapResult and overlapResult.separated > 0 then
        parts[#parts + 1] = overlapResult.separated
            .. " overlapping room" .. (overlapResult.separated == 1 and "" or "s")
            .. " separated"
    end
    if audit.duplicate_hash_rooms > 0 then
        parts[#parts + 1] = audit.duplicate_hash_rooms
            .. " duplicate-hash room" .. (audit.duplicate_hash_rooms == 1 and "" or "s")
            .. " remaining (re-enter to merge)"
    end
    if audit.overlapping_rooms > 0 then
        parts[#parts + 1] = audit.overlapping_rooms
            .. " overlapping room" .. (audit.overlapping_rooms == 1 and "" or "s")
            .. " remaining (no free cell / all locked)"
    end
    if audit.delta_mismatches > 0 then
        parts[#parts + 1] = audit.delta_mismatches
            .. " delta mismatch" .. (audit.delta_mismatches == 1 and "" or "es")
            .. " remaining (cyclic or unfixable)"
    end
    if audit.vertical_drift > 0 then
        parts[#parts + 1] = audit.vertical_drift
            .. " vertical drift" .. (audit.vertical_drift == 1 and "" or "s") .. " remaining"
    end
    if #parts == 0 then
        echo("No changes needed.\n")
    else
        echo(table.concat(parts, ", ") .. ".\n")
    end
end

function map.normalize_room_layout(maxPasses, maxMoves, allRooms, areaName)
    local userSuppliedMoves = maxMoves ~= nil
    maxPasses = maxPasses or map.configs.reconcile_deep_max_passes
    maxMoves  = maxMoves or map.configs.reconcile_deep_max_moves

    local areaID
    local currentRoomID
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
        currentRoomID = roomID
        areaID = getRoomArea(currentRoomID)
        if not areaID then
            echo("Cannot normalise: current room has no area.\n")
            return
        end
    end

    local areaName_display = getAreaTableSwap and getAreaTableSwap()[areaID] or ("area #" .. areaID)

    -- Warn early when the area is large: the full BFS + dedup passes below are
    -- O(rooms) with heavy per-room work and run synchronously, so Mudlet is
    -- unresponsive until they finish.  Give the user a chance to abort first.
    -- This deliberately keys off large_area_threshold rather than the (much
    -- higher) index cap — normalize is per-command work that is never amortised.
    if type(_.is_large_area) == "function" and _.is_large_area(areaID) then
        local cnt  = type(_.get_estimated_area_room_count) == "function"
                     and _.get_estimated_area_room_count(areaID) or "many"
        local thr  = tonumber(map.configs and map.configs.large_area_threshold) or 5000
        cecho(string.format(
            "<yellow>Warning: '%s' has ~%s rooms (threshold %d). "
            .. "Normalize runs synchronously and will freeze Mudlet until it "
            .. "finishes; the wait grows sharply with area size. "
            .. "Consider splitting the area into smaller sub-areas.\n<reset>",
            areaName_display, tostring(cnt), thr))
    end

    local areaRooms        = getAreaRooms(areaID)
    if type(areaRooms) ~= "table" then areaRooms = {} end

    -- Scale the reconcile move cap to the area size unless the user gave an
    -- explicit value.  Without this a large area bails out of the BFS after the
    -- static default (~5000) moves, leaving most rooms unpositioned and hugely
    -- inflating the "delta mismatches remaining" tally.
    if not userSuppliedMoves and type(_.scaled_reconcile_move_cap) == "function" then
        maxMoves = _.scaled_reconcile_move_cap(#areaRooms, maxPasses, maxMoves)
    end

    -- 1. Strip self-loop exits before BFS so the reconcile doesn't follow them.
    local selfLoopsRemoved = _.strip_self_loop_exits(areaRooms)

    local function run_normalize_pipeline()
        -- 2. De-duplicate rooms that share the same hash.
        --    This must run before reconcile because duplicate stubs cause phantom
        --    occupancy that blocks _.reconcile_connected_rooms from moving rooms.
        local posCache = _.build_pos_cache(areaID)
        local dedupeResult = map.dedupe_area_by_hash(areaID, posCache)
        -- Refresh room list after potential deletes
        areaRooms = getAreaRooms(areaID)
        if type(areaRooms) ~= "table" then areaRooms = {} end

        -- 3. Reconcile: BFS-move rooms to match their exits' expected deltas.
        local moved = 0
        if allRooms then
            echo("Normalising all subgraphs in '" .. areaName_display .. "'...\n")
            local globalVisited = {}
            local seedCount     = 0
            for _i, seedID in ipairs(areaRooms) do
                if not globalVisited[seedID] then
                    local subMoved = _.reconcile_connected_rooms(seedID, maxPasses, maxMoves, nil, globalVisited)
                    _.flatten_cardinal_connected_rooms(seedID)
                    moved = moved + (subMoved or 0)
                    seedCount = seedCount + 1
                end
            end
            echo("Normalised across " .. seedCount .. " subgraph" .. (seedCount == 1 and "" or "s") .. ".\n")
        else
            local seedID = currentRoomID and currentRoomID or find_best_seed(areaID)
            if not seedID then
                echo("Cannot normalise: no rooms with exits found in '" .. areaName_display .. "'.\n")
                return nil, nil, nil
            end
            echo("Normalising '" .. areaName_display .. "'...\n")
            moved = _.reconcile_connected_rooms(seedID, maxPasses, maxMoves)
            _.flatten_cardinal_connected_rooms(seedID)
        end

        -- 4. Snap in-area up/down room pairs to adjacent z-levels.
        local snapResult = _.snap_vertical_pair(areaID)

        -- 5. Anchor translate: align sub-graphs to game coordinate frame using
        --    user_data.coord values present on captured rooms.
        local freshPosCache = _.build_pos_cache(areaID)
        local anchorResult  = _.apply_anchor_translation(areaID, freshPosCache)

        return dedupeResult, moved, snapResult, anchorResult
    end

    local dedupeResult, moved, snapResult, anchorResult
    if currentRoomID and getRoomArea(currentRoomID) == areaID then
        dedupeResult, moved, snapResult, anchorResult = with_single_locked_anchor(currentRoomID, run_normalize_pipeline)
    else
        dedupeResult, moved, snapResult, anchorResult = run_normalize_pipeline()
    end
    if not dedupeResult then return end

    -- 6. Separate distinct rooms that landed on the same cell.  Only the
    --    room the normalize started from (if any) is treated as immovable
    --    here, matching the rest of the pipeline.
    local overlapResult = _.resolve_room_overlaps(areaID, nil, nil, currentRoomID)

    -- 7. Audit remaining anomalies in the (now-updated) area.
    local freshRooms = getAreaRooms(areaID)
    local audit = _.audit_layout_anomalies(type(freshRooms) == "table" and freshRooms or {}, areaID)

    updateMap()
    emit_repair_report(selfLoopsRemoved, moved or 0, snapResult, audit, dedupeResult, anchorResult, overlapResult)
end

function map.normalize_all_areas(maxPasses, maxMoves)
    local userSuppliedMoves = maxMoves ~= nil
    maxPasses   = maxPasses or map.configs.reconcile_deep_max_passes
    maxMoves    = maxMoves or map.configs.reconcile_deep_max_moves

    local areas = getAreaTable()
    if type(areas) ~= "table" then
        echo("Cannot normalise: no areas found.\n")
        return
    end

    local totalSelfLoops  = 0
    local totalDedupe     = 0
    local totalMoved      = 0
    local totalSnapped    = 0
    local totalTranslated = 0
    local totalSeparated  = 0
    local areaCount       = 0
    local areaNames      = {}
    for name, _ in pairs(areas) do areaNames[#areaNames + 1] = name end
    table.sort(areaNames)

    for _i, name in ipairs(areaNames) do
        local id        = areas[name]
        local areaRooms = getAreaRooms(id)
        if type(areaRooms) == "table" and #areaRooms > 0 then
            totalSelfLoops = totalSelfLoops + _.strip_self_loop_exits(areaRooms)
            local posCache     = _.build_pos_cache(id)
            local dedupeResult = map.dedupe_area_by_hash(id, posCache)
            totalDedupe = totalDedupe + (dedupeResult.removed or 0)
            areaRooms = getAreaRooms(id)
            if type(areaRooms) ~= "table" then areaRooms = {} end
            -- Scale the move cap to this area's size unless the user overrode it,
            -- so large areas fully normalise instead of bailing out early.
            local areaMaxMoves = maxMoves
            if not userSuppliedMoves and type(_.scaled_reconcile_move_cap) == "function" then
                areaMaxMoves = _.scaled_reconcile_move_cap(#areaRooms, maxPasses, maxMoves)
            end
            local globalVisited = {}
            for _j, seedID in ipairs(areaRooms) do
                if not globalVisited[seedID] then
                    local subMoved = _.reconcile_connected_rooms(seedID, maxPasses, areaMaxMoves, nil, globalVisited)
                    _.flatten_cardinal_connected_rooms(seedID)
                    totalMoved = totalMoved + (subMoved or 0)
                end
            end
            local snapResult = _.snap_vertical_pair(id)
            totalSnapped = totalSnapped + snapResult.snapped
            local freshPosCache = _.build_pos_cache(id)
            local anchorResult  = _.apply_anchor_translation(id, freshPosCache)
            totalTranslated = totalTranslated + (anchorResult.translated or 0)
            -- No single "current room" anchor across a bulk all-areas pass,
            -- so fall back to respecting real lock flags as before.
            local overlapResult = _.resolve_room_overlaps(id, freshPosCache, nil, nil, true)
            totalSeparated = totalSeparated + (overlapResult.separated or 0)
            areaCount    = areaCount + 1
        end
    end

    updateMap()
    local parts = {}
    if totalSelfLoops > 0 then
        parts[#parts + 1] = totalSelfLoops
            .. " self-loop exit" .. (totalSelfLoops == 1 and "" or "s") .. " removed"
    end
    if totalDedupe > 0 then
        parts[#parts + 1] = totalDedupe
            .. " duplicate room" .. (totalDedupe == 1 and "" or "s") .. " merged"
    end
    parts[#parts + 1] = totalMoved .. " room" .. (totalMoved == 1 and "" or "s") .. " repositioned"
    if totalSnapped > 0 then
        parts[#parts + 1] = totalSnapped
            .. " vertical pair" .. (totalSnapped == 1 and "" or "s") .. " snapped"
    end
    if totalTranslated > 0 then
        parts[#parts + 1] = totalTranslated
            .. " sub-graph" .. (totalTranslated == 1 and "" or "s")
            .. " aligned to game coords"
    end
    if totalSeparated > 0 then
        parts[#parts + 1] = totalSeparated
            .. " overlapping room" .. (totalSeparated == 1 and "" or "s") .. " separated"
    end
    echo(table.concat(parts, ", ") .. " across "
        .. areaCount .. " area" .. (areaCount == 1 and "" or "s") .. ".\n")
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

    local areaMergeResult = nil
    if type(_.merge_duplicate_areas_by_area_vnum) == "function" then
        areaMergeResult = _.merge_duplicate_areas_by_area_vnum(areaID)
        if areaMergeResult and type(areaMergeResult.target_area_id) == "number" and areaMergeResult.target_area_id > 0 then
            areaID = areaMergeResult.target_area_id
        end
    end

    local sx, sy, sz = getRoomCoordinates(seedID)
    if sx == nil then
        echo("Cannot recalculate: current room has no coordinates.\n")
        return
    end

    -- Strip self-loop exits so BFS does not traverse them.
    local areaRooms        = getAreaRooms(areaID)
    local selfLoopsRemoved = type(areaRooms) == "table" and _.strip_self_loop_exits(areaRooms) or 0

    -- Only the room the recalculation starts from is pinned; any other room
    -- (locked or not) may be repositioned so the BFS can rebuild the whole
    -- area consistently outward from here. Mirrors map normalize's anchor
    -- behaviour (see with_single_locked_anchor above).
    local movedCount, nudgeCount, deletedPlaceholderCount = 0, 0, 0
    local snapResult

    local function run_recalculate_pipeline()
    -- FIFO queue: each entry carries the position it was placed at. z comes
    -- purely from accumulated exit deltas (see the shift[3] below) — there is
    -- no name-based underground/elevated auto z-split. That heuristic used to
    -- force a z-jump whenever it crossed from a room whose name matched
    -- cave/tunnel/underground/etc. into one that didn't, which regularly tore
    -- a single, consistently-connected area (e.g. a den with rooms named
    -- "A tunnel under X" next to "A hallway in X") across two z-planes over
    -- an ordinary cardinal exit.
    local queue         = { { id = seedID, x = sx, y = sy, z = sz } }
    local qHead         = 1
    local visited       = { [seedID] = true }
    local occupied      = { [pos_key(sx, sy, sz)] = seedID }

    -- Build a reverse lookup: roomID → { x, y, z } for the post-BFS placeholder cleanup.
    local roomPositions = { [seedID] = { x = sx, y = sy, z = sz } }
    local MAX_BFS_ROOMS = 200000 -- safety cap; prevents indefinite freeze on huge areas

    while qHead <= #queue do
        if qHead > MAX_BFS_ROOMS then
            echo("[map recalculate] BFS capped at " .. MAX_BFS_ROOMS
                .. " rooms — area may be too large for a single pass.\n")
            break
        end
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

                        -- Collision avoidance: if the ideal position is already
                        -- taken by an earlier BFS room, nudge to the nearest
                        -- free spot so rooms don't stack on top of each other.
                        local posKey = pos_key(tx, ty, tz)
                        if occupied[posKey] then
                            if type(_.debug_echo) == "function" then
                                _.debug_echo("[recalculate] collision placing " .. targetID
                                    .. " (parent " .. entry.id .. " -" .. tostring(dir) .. "-> ), wanted ("
                                    .. tx .. "," .. ty .. "," .. tz .. "), already occupied by "
                                    .. tostring(occupied[posKey]) .. "\n")
                            end
                            tx, ty, tz = _.find_nearest_unoccupied(occupied, tx, ty, tz, shift)
                            posKey = pos_key(tx, ty, tz)
                            nudgeCount = nudgeCount + 1
                        end

                        local cx, cy, cz = getRoomCoordinates(targetID)
                        if safe_is_room_locked(targetID) and cx ~= nil then
                            -- Can't move this room: anchor its subtree to
                            -- where it REALLY is instead of the hypothetical
                            -- BFS-computed cell above. Using the computed
                            -- cell here would place every descendant relative
                            -- to a position the room was never actually moved
                            -- to, producing spurious delta mismatches through
                            -- the whole subtree.
                            occupied[posKey] = nil
                            tx, ty, tz = cx, cy, cz
                            posKey = pos_key(tx, ty, tz)
                        elseif cx ~= tx or cy ~= ty or cz ~= tz then
                            setRoomCoordinates(targetID, tx, ty, tz)
                            movedCount = movedCount + 1
                        end

                        occupied[posKey]        = targetID
                        roomPositions[targetID] = { x = tx, y = ty, z = tz }
                        table.insert(queue, { id = targetID, x = tx, y = ty, z = tz })
                    elseif type(_.debug_echo) == "function" then
                        _.debug_echo("[recalculate] skipped " .. targetID
                            .. " (parent " .. entry.id .. " -" .. tostring(dir)
                            .. "-> ): shift=" .. tostring(shift ~= nil)
                            .. " targetArea=" .. tostring(targetAreaID)
                            .. " areaID=" .. tostring(areaID) .. " (marked visited, never placed)\n")
                    end
                end
            end
        end
    end

    -- Post-BFS placeholder cleanup:
    --   (a) placeholders whose position overlaps a real room.
    --   (b) orphaned placeholders — every room whose exit points here is also
    --       a placeholder (the stub was created by a duplicate room that will
    --       never be properly visited).
    if type(deleteRoom) == "function" and type(_.is_placeholder) == "function" then
        -- Build a reverse-exit index over all BFS-visited rooms so we can
        -- cheaply check whether any real room leads to a given placeholder.
        local reverseVisited = {} -- target_roomID → true if any real visited room exits to it
        for src in pairs(visited) do
            if not _.is_placeholder(src) then
                local srcExits = getRoomExits(src)
                if type(srcExits) == "table" then
                    for _k, target in pairs(srcExits) do
                        reverseVisited[target] = true
                    end
                end
            end
        end

        for rid in pairs(visited) do
            if _.is_placeholder(rid) then
                local shouldDelete = false
                -- (a) positional collision with a real room.
                -- Use the occupied table built by the BFS instead of calling
                -- the expensive getRoomsByPosition Mudlet API per placeholder.
                local rpos = roomPositions[rid]
                if rpos then
                    local pkey     = pos_key(rpos.x, rpos.y, rpos.z)
                    local occupant = occupied[pkey]
                    if occupant and occupant ~= rid and not _.is_placeholder(occupant) then
                        shouldDelete = true
                    end
                end
                -- (b) orphaned: no real visited room has an exit leading here
                if not shouldDelete and not reverseVisited[rid] then
                    shouldDelete = true
                end
                if shouldDelete and _.delete_room(rid) then
                    deletedPlaceholderCount = deletedPlaceholderCount + 1
                end
            end
        end
    end

    -- Snap in-area up/down pairs that BFS may not have aligned (e.g. rooms
    -- unreachable from the seed, or sky rooms first reached via horizontal paths).
    snapResult = _.snap_vertical_pair(areaID)
    end -- run_recalculate_pipeline

    with_single_locked_anchor(seedID, run_recalculate_pipeline)

    -- Audit remaining anomalies in the final state.
    local freshRooms = getAreaRooms(areaID)
    local audit = _.audit_layout_anomalies(type(freshRooms) == "table" and freshRooms or {}, areaID)

    updateMap()
    local msg = "Topology recalculation repositioned " .. movedCount ..
        " room" .. (movedCount == 1 and "" or "s")
    local details = {}
    if selfLoopsRemoved > 0 then
        details[#details + 1] = selfLoopsRemoved
            .. " self-loop exit" .. (selfLoopsRemoved == 1 and "" or "s") .. " removed"
    end
    if areaMergeResult and areaMergeResult.merged_areas > 0 then
        details[#details + 1] = areaMergeResult.merged_areas
            .. " duplicate area" .. (areaMergeResult.merged_areas == 1 and "" or "s")
            .. " merged by area-vnum"
        local targetLabel = nil
        if type(areaMergeResult.target_area_name) == "string" and areaMergeResult.target_area_name ~= "" then
            targetLabel = "'" .. areaMergeResult.target_area_name .. "'"
        elseif type(areaMergeResult.target_area_id) == "number" then
            targetLabel = "area #" .. tostring(areaMergeResult.target_area_id)
        end
        details[#details + 1] = areaMergeResult.moved_rooms
            .. " room" .. (areaMergeResult.moved_rooms == 1 and "" or "s")
            .. " moved into " .. (targetLabel or "the target area")
        if areaMergeResult.removed_areas and areaMergeResult.removed_areas > 0 then
            details[#details + 1] = areaMergeResult.removed_areas
                .. " empty area" .. (areaMergeResult.removed_areas == 1 and "" or "s")
                .. " removed"
        end
    end
    if nudgeCount > 0 then
        details[#details + 1] = nudgeCount .. " nudged to avoid overlap"
    end
    if deletedPlaceholderCount > 0 then
        details[#details + 1] = deletedPlaceholderCount
            .. " placeholder" .. (deletedPlaceholderCount == 1 and "" or "s") .. " removed"
    end
    if snapResult.snapped > 0 then
        details[#details + 1] = snapResult.snapped
            .. " vertical pair" .. (snapResult.snapped == 1 and "" or "s") .. " snapped"
    end
    if snapResult.blocked > 0 then
        details[#details + 1] = snapResult.blocked
            .. " vertical snap" .. (snapResult.blocked == 1 and "" or "s") .. " blocked"
    end
    if snapResult.shared_target_bug > 0 then
        details[#details + 1] = snapResult.shared_target_bug
            .. " shared-target bug" .. (snapResult.shared_target_bug == 1 and "" or "s")
            .. " (data issue)"
    end
    if audit.duplicate_hash_rooms > 0 then
        details[#details + 1] = audit.duplicate_hash_rooms
            .. " duplicate-hash room" .. (audit.duplicate_hash_rooms == 1 and "" or "s")
            .. " (re-enter to merge)"
    end
    if audit.delta_mismatches > 0 then
        details[#details + 1] = audit.delta_mismatches
            .. " delta mismatch" .. (audit.delta_mismatches == 1 and "" or "es")
            .. " remaining"
    end
    if #details > 0 then
        msg = msg .. " (" .. table.concat(details, ", ") .. ")"
    end
    echo(msg .. ".\n")
end
