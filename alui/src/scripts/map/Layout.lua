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

-- Exit-agreement score for a room, optionally at a hypothetical position.
-- Falls back to "no information" (0) rather than erroring if Helpers has not
-- been loaded into the namespace yet, which makes reconcile behave exactly as
-- it did before eviction existed: 0 never beats 0, so nothing is displaced.
local function safe_exit_consistency_score(rid, x, y, z)
    local fn = _.exit_consistency_score
    if type(fn) ~= "function" then return 0 end
    return fn(rid, x, y, z)
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

-- infoOverride: a stand-in for map.room_info, supplied by the deferred
-- neighbour queue in Core.lua.  Only `exits` is ever read, so the override is
-- just `{ exits = { [dir] = targetVnum } }`.  Two things make that useful:
-- the queue runs long after the player has moved on, so the live map.room_info
-- describes a different room entirely; and passing a single exit turns one call
-- into one unit of work, which is how the wiring gets chunked finely enough to
-- keep Mudlet responsive.  Per-call setup (the pos cache lookup, getRoomExits,
-- forced z) is all sub-millisecond, so paying it per exit is not a real cost.
function _.create_neighbors_for_current_room(roomID, posCache, infoOverride)
    local info = infoOverride or map.room_info
    if type(info) ~= "table" or type(info.exits) ~= "table" then return end
    if type(roomID) ~= "number" or roomID < 1 then return end

    local areaID = getRoomArea(roomID)
    if not areaID or areaID < 1 then return end

    local cx, cy, cz = getRoomCoordinates(roomID)
    if cx == nil then return end

    -- Build the position cache here if the caller didn't supply one.  Sharing
    -- it with handle_move/reconcile avoids repeated O(area) walks per event.
    -- For large areas skip the O(N) full build and use the _large_area
    -- sentinel: _.rooms_at_position treats that as "no data" and falls back to
    -- getRoomsByPosition, while for a real cache an empty cell is answered from
    -- the cache itself.
    if posCache == nil or posCache._areaID ~= areaID then
        if type(_.is_large_area) == "function" and _.is_large_area(areaID) then
            posCache = { _areaID = areaID, _rooms = {}, _large_area = true }
        else
            posCache = _.build_pos_cache(areaID)
        end
    end

    -- Whether an exit to a room we have never seen gets a placeholder room or
    -- just an exit stub.  Placeholders are what make the map show unexplored
    -- exits and are what add_placeholder_exits chains together to route autowalk
    -- through unmapped space, but on a large area each one costs roughly half a
    -- second to create and most are never walked.  Above the large-area
    -- threshold the stub carries the same information for free, and the exit to
    -- the real room gets written on arrival instead (handle_move, Core.lua).
    local stubUnexplored   = map.configs.stub_unexplored_exits ~= false
        and type(_.is_large_area) == "function" and _.is_large_area(areaID)

    local forcedZ          = _.get_forced_z_for_room(roomID)
    local createdCount     = 0
    -- Track only the positions touched this event so the backstop dedup
    -- doesn't have to walk the entire area posCache on every player step.
    local touchedPositions = {}

    -- This room's exits, read once and kept current as we write to them.
    --
    -- setExit is not a cheap call the way the getters are: on a very large area
    -- it was measured at ~100ms against ~0ms for getRoomExits, because it has to
    -- touch the area's exit structure rather than look one room up.  The write
    -- below used to fire once per GMCP exit on *every* arrival, so walking
    -- through rooms that were already mapped correctly — by far the common case
    -- once an area is explored — spent most of a second per step rewriting exits
    -- to the values they already held.  Reading the room's exits once and
    -- skipping the no-op writes removes that entirely.
    --
    -- Kept current rather than re-read because the dedup backstop below also
    -- writes exits on roomID, and it needs to see what this loop already set.
    local myExits = nil

    local function my_exits()
        if myExits == nil then myExits = getRoomExits(roomID) or false end
        return myExits or nil
    end

    -- True when roomID's `exitDir` already points at targetID, so writing it
    -- would be a no-op.  String targets are normalised because getRoomExits is
    -- not consistent about returning ids as numbers.
    local function exit_already_set(exitDir, targetID)
        local ex = my_exits()
        if type(ex) ~= "table" then return false end
        local cur = ex[exitDir]
        if type(cur) == "string" then cur = tonumber(cur) end
        return cur == targetID
    end

    local function note_exit(exitDir, targetID)
        local ex = my_exits()
        if type(ex) == "table" then ex[exitDir] = targetID end
    end

    for dir, targetVnum in pairs(info.exits) do
        if type(targetVnum) ~= "string" then
            -- skip bad values
        else
            local shift    = _.get_shift_for_exit_key(dir)

            -- Mudlet's own name for this direction, or nil for a non-standard
            -- GMCP key (portals, custom commands).  setExit and setExitStub both
            -- reject anything else.  Resolved once here because the stub path
            -- below and the exit write at the end of the loop both need it.
            local exitDir = _.normalize_exit_direction(dir)
            if not exitDir then
                local d = type(dir) == "string" and string.lower(dir) or nil
                if d == "in" or d == "out" then exitDir = d end
            end

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
                -- Answered from posCache, except on a large-area sentinel where
                -- it falls back to Mudlet's native positional look-up.
                local near = _.rooms_at_position(posCache, areaID, tx, ty, tz)
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
                    local near = _.rooms_at_position(posCache, areaID, tx, ty, tz)
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
                        _.note_room_event(candidateID, "adopted-by-position",
                            tostring(roomID) .. ":" .. tostring(dir))
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

            if targetID < 1 and stubUnexplored then
                -- Nothing exists for this vnum yet, and on an area this size a
                -- placeholder room is far too expensive to stand up for an exit
                -- the player may never take (~396ms in setRoomArea alone, against
                -- no measurable cost for a stub).  Mark the direction and stop:
                -- with no room there is nothing to place, dedup or wire.  The
                -- exit becomes a real one the moment the player walks it, wired
                -- from the far side by handle_move.
                if exitDir then _.ensure_exit_stub(roomID, exitDir) end
            elseif targetID < 1 then
                targetID = createRoomID()
                _.add_room(targetID)
                -- Created because the room the player is in reported an exit
                -- this way, not because anyone went there.
                _.stamp_room_origin(targetID, "neighbour-of",
                    tostring(roomID) .. ":" .. tostring(dir))
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

            -- Only reachable with a real target room; the stub path above
            -- leaves targetID unset precisely so all of this is skipped.
            if targetID > 0 then
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
                        _.set_room_coordinates(targetID,
                            cx + shift[1], cy + shift[2], cz + shift[3], posCache)
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
                        local hits = _.rooms_at_position(posCache, areaID, fx, fy, fz)
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
                                        -- The survivor now wears a real room's name without
                                        -- having been entered for it; say where that came from.
                                        _.inherit_room_provenance(keep, dup)
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

                -- Set the forward exit from current room to the neighbour.
                -- One-directional is intentional: GMCP is authoritative, the reverse
                -- will be set properly when the player actually enters that room.
                -- map recalculate only needs forward exits to BFS-position rooms.
                -- Skip the write when the exit already points where we want it.
                -- GMCP stays authoritative: any exit that differs is still written.
                if exitDir and not exit_already_set(exitDir, targetID) then
                    setExit(roomID, targetID, exitDir)
                    note_exit(exitDir, targetID)
                end
            end
        end
    end

    -- Final positional dedup backstop.  Only checks positions that were
    -- actually touched this event (at most one per GMCP exit direction),
    -- instead of scanning the entire area posCache.  This keeps the cost
    -- O(exits) ≈ O(12) rather than O(all rooms in area) per player step.
    do
        -- Shares the exit table with the loop above rather than re-reading it:
        -- the rewrites below have to see the exits that loop just set, and the
        -- guard up there has to see the ones this block rewires.
        local get_my_exits = my_exits
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
                            _.inherit_room_provenance(keep, dup)
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
                            -- Collect first, then write: `myExits` is now the
                            -- shared table, and note_exit assigns into it, so
                            -- rewiring during the walk would mutate the very
                            -- table being iterated.
                            local rewire = {}
                            for d, tgt in pairs(myExits) do
                                if type(tgt) == "string" then tgt = tonumber(tgt) end
                                if tgt == dup then
                                    local nd = has_norm and _.normalize_exit_direction(d) or d
                                    if type(nd) == "string" then
                                        rewire[#rewire + 1] = nd
                                    end
                                end
                            end
                            for _r = 1, #rewire do
                                pcall(setExit, roomID, keep, rewire[_r])
                                note_exit(rewire[_r], keep)
                            end
                        end
                        _.delete_room(dup)
                        -- Remove by value, not by index: `list` is the cache's
                        -- own occupant array for this cell, and _.delete_room
                        -- drops the room from the long-lived cache — which, on
                        -- the normal handle_move path, is this very cache.  An
                        -- index-based remove would then delete whichever live
                        -- room shifted into slot i.  `i` is not advanced either
                        -- way, since one entry has left the list.
                        for j = #list, 1, -1 do
                            if list[j] == dup then table.remove(list, j) end
                        end
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
-- externalPosCache: optional position cache for the anchor's area, shared the
-- same way.  It is mutated in place as rooms move, so a seed loop should thread
-- one through every seed rather than paying an O(area) build per seed.
function _.reconcile_connected_rooms(anchorID, maxPasses, maxMoves, maxDepth, externalVisited, externalPosCache)
    maxPasses = maxPasses or map.configs.reconcile_max_passes
    maxMoves  = maxMoves or map.configs.reconcile_max_moves

    if type(anchorID) ~= "number" or anchorID < 1 then return end
    local areaID = getRoomArea(anchorID)
    if not areaID then return end

    local ax, ay, az = getRoomCoordinates(anchorID)
    if ax == nil then return end

    -- If the caller supplied a cache for this area, reuse it (and feed our own
    -- mutations back into it for downstream callers).  Otherwise build one
    -- here.  Either way it is built once for the whole call: every move below
    -- is mirrored into the cache by set_room_coordinates, so the passes converge
    -- in-place and a per-pass rebuild would be maxPasses (default 20) O(area)
    -- walks that all produce the cache we are already holding.
    local posCache = (externalPosCache and externalPosCache._areaID == areaID)
        and externalPosCache
        or _.build_pos_cache(areaID)

    -- Cells this call has already taken away from a given room, keyed
    -- "x,y,z#roomID".  Two rooms can each be the better-anchored one at
    -- different moments (their scores change as the block around them moves),
    -- so without this an A-evicts-B / B-evicts-A pair would trade the same cell
    -- back and forth for every remaining pass.  Refusing a repeat of the exact
    -- same eviction caps that trade at one round.
    local evictedFrom = {}
    local evictRadius = tonumber(map.configs.reconcile_evict_radius) or 8

    -- Eviction only makes sense when the run has passes left to re-derive the
    -- displaced room's real position, so it is confined to the multi-pass repair
    -- commands (map normalize / map recalculate).  The per-step path runs a
    -- single pass and keeps the old skip-on-occupied behaviour: parking a room
    -- on an arbitrary free cell with no pass to follow up is the very thing that
    -- strands rooms.  Occupancy also has to be real — a large-area sentinel
    -- cache reports every cell as free, so "nearest free cell" would be a guess.
    local evictEnabled =
        maxPasses > 1
        and map.configs.reconcile_evict ~= false
        and type(_.pos_cache_is_authoritative) == "function"
        and _.pos_cache_is_authoritative(posCache, areaID)

    -- Try to clear `blockers` off (x, y, z) so `targetID` can have it.
    --
    -- Repeated passes fix a contested cell on their own only when something
    -- eventually moves the occupant, and a pass can only move a room some other
    -- room's exit points at.  So two kinds of squatter are permanent: one no
    -- exit points at at all, and one whose own position already satisfies its
    -- own exits, so no pass has a reason to touch it.  Either strands every room
    -- that legitimately belongs on that cell, and that room in turn strands
    -- whatever belongs on the cell it is stuck on: the wall of delta mismatches
    -- along a seam is usually one squatter and a chain behind it.
    --
    -- Letting the incoming room displace a *strictly worse anchored* occupant
    -- breaks the chain at the weak end (an exit-less placeholder scores 0 and
    -- always yields) while never trading a good placement for a worse one.
    --
    -- The evicted room is nudged to the nearest free cell rather than given a
    -- considered home: it is by construction the room that agrees with its
    -- neighbours least, and the next pass re-derives its position from whichever
    -- neighbour points at it, so a temporary parking spot costs nothing.
    -- Returns true when the cell is now free for targetID.
    local function evict_blockers(blockers, targetID, x, y, z)
        if not evictEnabled then return false end
        -- More than one blocker means the cell is already double-booked, which
        -- is resolve_room_overlaps' job, not ours.
        if #blockers ~= 1 then return false end
        if type(_.find_free_cell_near) ~= "function" then return false end

        local oid = blockers[1]
        if oid == anchorID or safe_is_room_locked(oid) then return false end

        local cellKey = x .. "," .. y .. "," .. z .. "#" .. oid
        if evictedFrom[cellKey] then return false end

        -- Strictly better, judged on the same measure for both: how many of the
        -- room's own exits land exactly where they should.  Ties keep the
        -- incumbent, so an incoming room with nothing to say (score 0) never
        -- displaces anyone.
        local incoming = safe_exit_consistency_score(targetID, x, y, z)
        if incoming < 1 then return false end
        if safe_exit_consistency_score(oid) >= incoming then return false end

        local ox, oy, oz = getRoomCoordinates(oid)
        if ox == nil then return false end
        local fx, fy, fz = _.find_free_cell_near(posCache, ox, oy, oz, evictRadius)
        if fx == nil then return false end

        _.set_room_coordinates(oid, fx, fy, fz, posCache)
        evictedFrom[cellKey] = true
        return true
    end

    local moved = 0
    for _pass = 1, maxPasses do
        local passMove = 0

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

                                    local occupants = _.pos_cache_get(posCache,
                                        expectedX, expectedY, expectedZ)
                                    local blockers  = {}
                                    if type(occupants) == "table" then
                                        for _, oid in ipairs(occupants) do
                                            if oid ~= targetID then
                                                blockers[#blockers + 1] = oid
                                            end
                                        end
                                    end

                                    local alreadyOccupied = #blockers > 0
                                    if alreadyOccupied and not safe_is_room_locked(targetID)
                                        and evict_blockers(blockers, targetID,
                                            expectedX, expectedY, expectedZ) then
                                        -- The evicted room was repositioned too, so it
                                        -- counts against maxMoves like any other move.
                                        alreadyOccupied = false
                                        passMove        = passMove + 1
                                        moved           = moved + 1
                                        if moved >= maxMoves then return moved end
                                    end

                                    if not alreadyOccupied and not safe_is_room_locked(targetID) then
                                        local tx, ty, tz = getRoomCoordinates(targetID)
                                        -- Use expectedZ directly: it already reflects the anchor's
                                        -- actual z-plane. Overriding with forcedZ was what snapped
                                        -- terrain-labelled rooms to z=0 even when the whole cluster
                                        -- lives at a different z (e.g. forest grid at z=33).
                                        if tx ~= expectedX or ty ~= expectedY or tz ~= expectedZ then
                                            _.set_room_coordinates(targetID,
                                                expectedX, expectedY, expectedZ, posCache)
                                            passMove = passMove + 1
                                            moved    = moved + 1
                                            if moved >= maxMoves then return moved end
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
-- externalPosCache: optional cache for this area.  Callers that run this
-- between reconcile seeds must pass the same cache they gave reconcile, or the
-- setRoomCoordinates calls below leave it claiming rooms sit on their old z.
function _.flatten_cardinal_connected_rooms(anchorID, externalPosCache)
    if type(anchorID) ~= "number" or anchorID < 1 then return end
    local areaID = getRoomArea(anchorID)
    if not areaID then return end

    local posCache = (externalPosCache and externalPosCache._areaID == areaID)
        and externalPosCache or nil

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
                            -- set_room_coordinates mirrors only a fully
                            -- coordinated move, so a nil cz (current room has no
                            -- coords) cannot reach pc_key's concatenation.
                            _.set_room_coordinates(targetID, tx, ty, cz, posCache)
                        end
                        table.insert(queue, targetID)
                    end
                end
            end
        end
    end
end

-- --------------------------------------------------------------------------
-- Placement: absolute elevation
-- --------------------------------------------------------------------------

-- Put roomID on the z-plane its own nature says it belongs on: 0 for surface
-- terrain, 1..sky_max_level for a room in the air (see _.anchor_z_for_room).
--
-- This moves one room and never a group, which is the whole point of an anchor.
-- realign has to carry a group because its evidence is relative — it learns
-- "one east of that room", and that is only as good as where that room sits.
-- An anchor reads no neighbour's coordinates at all, so every room reaches the
-- right plane on its own, in any order, as the player visits it.  A whole
-- displaced layer therefore repairs itself room by room rather than needing one
-- enormous translation the client could not absorb in a single step.
--
-- Returns `moved, anchorZ`.  anchorZ is reported even when nothing moved, so a
-- caller can tell "already on its plane" from "no plane is known" — the first
-- must not be second-guessed by a heuristic, the second is exactly what
-- heuristics are for.
function _.apply_elevation_anchor(roomID, posCache, info, depth)
    if type(_.anchor_z_for_room) ~= "function" then return false, nil end
    if type(roomID) ~= "number" or roomID < 1 then return false, nil end

    local anchorZ = _.anchor_z_for_room(roomID, info)
    if type(anchorZ) ~= "number" then return false, nil end
    if safe_is_room_locked(roomID) then return false, anchorZ end

    local areaID = getRoomArea(roomID)
    if type(areaID) ~= "number" or areaID < 1 then return false, anchorZ end
    local rx, ry, rz = getRoomCoordinates(roomID)
    if rx == nil or rz == anchorZ then return false, anchorZ end

    -- Something may already hold this x/y on the correct plane, and when a whole
    -- sky stack is a level low it is guaranteed: the room in the way is the next
    -- one up the same column, which has an anchor of its own and one more plane
    -- to climb.  Ask it to move first.  A stack is at most sky_max_level deep
    -- and each step up is a strictly higher plane, so this bottoms out; a room
    -- with no anchor, or one that cannot move either, still blocks and we yield.
    local blockers  = {}
    local occupants = _.rooms_at_position(posCache, areaID, rx, ry, anchorZ)
    if type(occupants) == "table" then
        -- Copied out first: the recursion below moves rooms, and on a cached
        -- area `occupants` is the cache's own live list for that cell.
        for i = 1, #occupants do
            if occupants[i] ~= roomID then blockers[#blockers + 1] = occupants[i] end
        end
    end
    if #blockers > 0 then
        local nextDepth = (tonumber(depth) or 0) + 1
        if nextDepth > (tonumber(map.configs.sky_max_level) or 3) then
            return false, anchorZ
        end
        for i = 1, #blockers do
            -- A true return means the blocker moved to a different plane, so it
            -- has necessarily left this cell.
            if not _.apply_elevation_anchor(blockers[i], posCache, nil, nextDepth) then
                return false, anchorZ
            end
        end
    end

    _.set_room_coordinates(roomID, rx, ry, anchorZ, posCache)
    _.debug_echo(string.format(
        "elevation anchor: room %d z %d→%d\n", roomID, rz, anchorZ))
    return true, anchorZ
end

-- --------------------------------------------------------------------------
-- Placement: realign a displaced room onto the cluster it adjoins
-- --------------------------------------------------------------------------

-- A room can end up nowhere near the rooms it actually adjoins.  make_room
-- places a new room by offsetting the previous one, and when the arrival gave it
-- no directional clue — a gapped event queue, a portal, a special exit — it falls
-- back to probing for any free cell nearby.  Whatever it picks is a guess, and
-- the guess is only found out later, once the room's exits are learned and turn
-- out to point at a cluster several cells away.
--
-- reconcile_connected_rooms already repairs this shape of error, but only from
-- the far end: it walks outward from a trusted anchor and drags targets into
-- place, which costs an O(area) pos-cache build and a multi-room BFS — far too
-- much to run on every arrival, which is why auto_reconcile is off.  Here the
-- displaced room is the one already in hand and its own exits carry the answer,
-- so the judgement is entirely local and made of free reads: every exit landing
-- on a room that has coordinates implies exactly one position for this room, and
-- the position the most exits agree on wins.
--
-- The room does not travel alone.  Anything reachable through exits that are
-- *already* consistent was displaced by the same delta, so it moves too; the
-- translation is rigid, which leaves every internal delta untouched.  That is
-- also what makes this stable rather than oscillating: after the move the
-- winning position is where the room sits, so a second call finds nothing to do.
--
-- `info` is the live GMCP snapshot when the caller has one; it is only consulted
-- for the room's name and terrain, which on a first visit the map does not carry
-- yet.  Pass nil for an already-known room.
--
-- Returns the number of rooms moved (0 when it declines).
function _.realign_displaced_room(roomID, posCache, info)
    if map.configs.realign_displaced_rooms == false then return 0 end
    if type(roomID) ~= "number" or roomID < 1 then return 0 end
    if safe_is_room_locked(roomID) then return 0 end

    local areaID = getRoomArea(roomID)
    if type(areaID) ~= "number" or areaID < 1 then return 0 end
    local rx, ry, rz = getRoomCoordinates(roomID)
    if rx == nil then return 0 end
    local exits = getRoomExits(roomID)
    if type(exits) ~= "table" then return 0 end

    -- The plane this room belongs on, if anything establishes one.  Candidates
    -- off it are discarded, so the exit vote can move the room around within its
    -- plane but never off it.  apply_elevation_anchor has already put the room
    -- there; without this filter the room's own cluster — internally consistent
    -- by construction, and therefore voting confidently for the old z — would
    -- simply pull it back on the next arrival.
    local anchorZ = type(_.anchor_z_for_room) == "function"
        and _.anchor_z_for_room(roomID, info) or nil

    -- One vote per exit that lands on a placed room in this area.  Canonical
    -- exit order so that when two candidates tie, which one is "first" is the
    -- same on every run (the tie is rejected below either way, but the debug
    -- output should not vary).
    local votes, best, bestVotes, bestKey = {}, nil, 0, nil
    local voters = {}
    for dir, targetID in _.sorted_exit_pairs(exits) do
        if type(targetID) == "string" then targetID = tonumber(targetID) end
        if type(targetID) == "number" and targetID > 0 and targetID ~= roomID
            and getRoomArea(targetID) == areaID then
            local shift = _.get_shift_for_exit_key(dir)
            if shift then
                local tx, ty, tz = getRoomCoordinates(targetID)
                if tx ~= nil and (anchorZ == nil or (tz - shift[3]) == anchorZ) then
                    local px, py, pz = tx - shift[1], ty - shift[2], tz - shift[3]
                    local key  = pos_key(px, py, pz)
                    local slot = votes[key]
                    if slot then
                        slot.n = slot.n + 1
                    else
                        slot = { n = 1, x = px, y = py, z = pz }
                        votes[key] = slot
                        voters[key] = {}
                    end
                    voters[key][targetID] = true
                    if slot.n > bestVotes then
                        best, bestVotes, bestKey = slot, slot.n, key
                    end
                end
            end
        end
    end

    local minVotes = tonumber(map.configs.realign_min_votes) or 2
    if best == nil or bestVotes < minVotes then return 0 end
    -- Already where the winner says it belongs: the common case, and the reason
    -- this is safe to call on every arrival.
    if bestKey == pos_key(rx, ry, rz) then return 0 end

    -- The winner has to beat every other candidate outright, including wherever
    -- the room currently sits.  A tie is two clusters disagreeing about where
    -- this room goes, and picking one of them on a coin toss would just undo
    -- itself the moment the loser gained an exit.
    for key, slot in pairs(votes) do
        if key ~= bestKey and slot.n >= bestVotes then return 0 end
    end

    local dx, dy, dz = best.x - rx, best.y - ry, best.z - rz
    local maxComponent = tonumber(map.configs.realign_max_component) or 32

    -- The rooms displaced along with this one: everything reachable through
    -- exits that already sit at exactly the delta they imply.  Exits that do
    -- *not* — which is every exit that voted for the winner — are the seam we
    -- are closing, so the cluster on their far side is left where it is.
    local component   = { roomID }
    local inComponent = { [roomID] = true }
    local head        = 1
    while head <= #component do
        local current    = component[head]
        head             = head + 1
        local cx, cy, cz = getRoomCoordinates(current)
        local cex        = getRoomExits(current)
        if cx ~= nil and type(cex) == "table" then
            for dir, tid in _.sorted_exit_pairs(cex) do
                if type(tid) == "string" then tid = tonumber(tid) end
                if type(tid) == "number" and tid > 0 and not inComponent[tid]
                    and getRoomArea(tid) == areaID then
                    local shift = _.get_shift_for_exit_key(dir)
                    if shift then
                        local tx, ty, tz = getRoomCoordinates(tid)
                        if tx ~= nil and (tx - cx) == shift[1]
                            and (ty - cy) == shift[2] and (tz - cz) == shift[3] then
                            -- A component that keeps growing has reached the
                            -- main body of the map through some other seam, and
                            -- translating that is map normalize's job, not ours.
                            if #component >= maxComponent then return 0 end
                            if safe_is_room_locked(tid) then return 0 end
                            inComponent[tid] = true
                            component[#component + 1] = tid
                        end
                    end
                end
            end
        end
    end

    -- If a room that voted for the winner is itself being moved, the evidence is
    -- self-referential: the group would carry its own reference point along with
    -- it and land somewhere neither cluster asked for.
    for tid in pairs(voters[bestKey]) do
        if inComponent[tid] then return 0 end
    end

    -- Nothing may already occupy the cells the group is moving onto.  This is
    -- the one question a large area's position cache cannot answer (it holds no
    -- coordinate map there), so it falls through to getRoomsByPosition — the
    -- only real cost in the whole function, and the reason the component is
    -- capped.  It is paid solely when a move is otherwise going ahead.
    for i = 1, #component do
        local id         = component[i]
        local cx, cy, cz = getRoomCoordinates(id)
        local occupants  = _.rooms_at_position(posCache, areaID,
            cx + dx, cy + dy, cz + dz)
        if type(occupants) == "table" then
            for j = 1, #occupants do
                if not inComponent[occupants[j]] then return 0 end
            end
        end
    end

    for i = 1, #component do
        local id         = component[i]
        local cx, cy, cz = getRoomCoordinates(id)
        _.set_room_coordinates(id, cx + dx, cy + dy, cz + dz, posCache)
    end

    _.debug_echo(string.format(
        "realign: room %d (%d,%d,%d)→(%d,%d,%d) on %d agreeing exit(s); "
        .. "%d room(s) moved with it\n",
        roomID, rx, ry, rz, best.x, best.y, best.z, bestVotes, #component))
    return #component
end

-- --------------------------------------------------------------------------
-- Public layout commands
-- --------------------------------------------------------------------------

-- Run fn under the lock policy the repair commands use: only the room the
-- command started from counts as pinned, so an old pin elsewhere in the area
-- cannot stop a repair from spreading outward.  With no anchor room there is
-- nothing to make an exception for and real locks apply as usual.
local function with_anchor_policy(anchorRoomID, fn)
    if anchorRoomID == nil then return fn() end
    return with_single_locked_anchor(anchorRoomID, fn)
end

-- Everything both layout commands do once their coordinates exist.
--
-- The two differ in one thing only: how the coordinates are produced.  Normalize
-- corrects the ones already on the map, recalculate throws them away and derives
-- new ones by walking out from the room you are standing in.  What has to happen
-- afterwards is the same work on the same finished positions — and it used to be
-- written out twice, which is how recalculate came to be missing two stages it
-- has as much use for as normalize does.
--
-- `result` is the accumulating report table the caller's own stages have already
-- written their counts into; the stages here add theirs and it is handed to
-- emit_layout_report.
--
-- opts.anchorRoomID    the room the command started from, or nil.  Stages that
--                      reposition against the existing layout run under
--                      with_anchor_policy; the elevation pass deliberately does
--                      not.  It moves whole groups rigidly, so nothing shifts
--                      relative to the anchor and that policy has nothing left to
--                      protect, while a real `map lock` does have something to
--                      say about which plane its room sits on.  Which policy
--                      applied used to depend on where a closure happened to end.
-- opts.respectRealLocks  passed to the overlap pass by bulk runs that have no
--                      single anchor to pin instead.
-- opts.audit           false to skip the anomaly audit, for callers that report
--                      cross-area totals and would otherwise pay an O(area) walk
--                      per area for numbers they never print.
function _.finish_layout_repair(areaID, posCache, result, opts)
    opts   = opts or {}
    result = result or {}
    local anchorRoomID = opts.anchorRoomID

    with_anchor_policy(anchorRoomID, function()
        -- Snap in-area up/down room pairs to adjacent z-levels.
        result.snap = _.snap_vertical_pair(areaID, posCache)

        -- Align sub-graphs to the game's coordinate frame using the
        -- user_data.coord values stored during room capture.  x/y only, so it
        -- cannot undo the elevation pass below.
        result.anchor = _.apply_anchor_translation(areaID, posCache)
    end)

    -- Put groups of rooms on the z-plane their own terrain and names say they
    -- belong on.  This is the only absolute statement about height in either
    -- command: everything above derives z by adding a walked shift to the room
    -- it came from, so without this an area keeps whatever plane it was first
    -- mapped onto.
    result.elevation = _.apply_elevation_planes(areaID, posCache)

    -- Separate distinct rooms that ended up on the same cell.  Not wrapped: it
    -- takes the anchor room directly and consults lock flags only when asked to.
    result.overlap = _.resolve_room_overlaps(areaID, posCache, nil,
        anchorRoomID, opts.respectRealLocks)

    if opts.audit ~= false then
        local freshRooms = getAreaRooms(areaID)
        result.audit = _.audit_layout_anomalies(
            type(freshRooms) == "table" and freshRooms or {}, areaID)
    end
    return result
end

local function plural(n, word)
    if n == 1 then return word end
    if word:sub(-2) == "ch" then return word .. "es" end
    return word .. "s"
end

local function count(n, word, tail)
    return n .. " " .. plural(n, word) .. (tail and (" " .. tail) or "")
end

-- Shared bucketed report emitted at the end of normalize and recalculate, in
-- pipeline order.  `result` is the table _.finish_layout_repair fills in; a
-- caller that never ran a stage simply leaves its field nil and the stage is
-- not mentioned.  result.headline, when set, becomes the leading sentence and
-- the rest is parenthesised after it.
local function emit_layout_report(result)
    local parts = {}
    local function add(s) parts[#parts + 1] = s end
    local function tally(n, word, tail)
        if (tonumber(n) or 0) > 0 then add(count(n, word, tail)) end
    end

    tally(result.self_loops, "self-loop exit", "removed")

    local merge = result.area_merge
    if merge and (merge.merged_areas or 0) > 0 then
        add(count(merge.merged_areas, "duplicate area", "merged by area-vnum"))
        local targetLabel = nil
        if type(merge.target_area_name) == "string" and merge.target_area_name ~= "" then
            targetLabel = "'" .. merge.target_area_name .. "'"
        elseif type(merge.target_area_id) == "number" then
            targetLabel = "area #" .. tostring(merge.target_area_id)
        end
        add(count(merge.moved_rooms, "room",
            "moved into " .. (targetLabel or "the target area")))
        tally(merge.removed_areas, "empty area", "removed")
    end

    if result.dedupe then
        tally(result.dedupe.removed, "duplicate room", "merged")
        tally(result.dedupe.skipped, "duplicate group", "skipped (all locked)")
    end

    tally(result.moved, "room", "repositioned")
    if (tonumber(result.nudged) or 0) > 0 then
        add(result.nudged .. " nudged to avoid overlap")
    end
    tally(result.placeholders_removed, "placeholder", "removed")

    if result.snap then
        tally(result.snap.snapped, "vertical pair", "snapped")
        tally(result.snap.blocked, "vertical snap", "blocked by occupant")
        tally(result.snap.shared_target_bug, "shared-target bug",
            "(in-area duplicate exit, data issue)")
    end

    if result.anchor then
        tally(result.anchor.translated, "sub-graph", "aligned to game coords")
        tally(result.anchor.unanchored_subgraphs, "sub-graph", "unanchored (no coord data)")
        tally(result.anchor.anchor_disagreements, "anchor disagreement",
            "(picked lowest-id anchor)")
        tally(result.anchor.skipped, "sub-graph", "not translated (locked room or collision)")
    end

    if result.elevation then
        if (result.elevation.rooms_shifted or 0) > 0 then
            add(count(result.elevation.rooms_shifted, "room", "moved onto their elevation in "
                .. count(result.elevation.shifted, "group")))
        end
        tally(result.elevation.anchored, "room", "elevated individually")
        tally(result.elevation.blocked, "elevation group",
            "blocked (locked room or occupied plane)")
    end

    if result.overlap then
        tally(result.overlap.separated, "overlapping room", "separated")
    end

    if result.audit then
        tally(result.audit.duplicate_hash_rooms, "duplicate-hash room",
            "remaining (re-enter to merge)")
        tally(result.audit.overlapping_rooms, "overlapping room",
            "remaining (no free cell / all locked)")
        tally(result.audit.delta_mismatches, "delta mismatch",
            "remaining (cyclic or unfixable)")
        tally(result.audit.vertical_drift, "vertical drift", "remaining")
    end

    if result.headline then
        echo(result.headline
            .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "") .. ".\n")
    elseif #parts == 0 then
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

    -- Strip self-loop exits before BFS so the reconcile doesn't follow them.
    local result = { self_loops = _.strip_self_loop_exits(areaRooms) }

    -- Only pin the room the command started from when it is actually in the
    -- area being worked on; otherwise there is nothing to make an exception for
    -- and real locks apply.  Shared by the middle below and the tail after it.
    local anchorRoomID = (currentRoomID and getRoomArea(currentRoomID) == areaID)
        and currentRoomID or nil

    -- One position cache for the whole command.  Every stage needs occupancy for
    -- this area, and each used to build its own — an O(area) getRoomCoordinates
    -- walk apiece.  Every stage mutates the cache in place as it moves or deletes
    -- rooms (set_room_coordinates mirrors moves; delete sites drop via
    -- pos_cache_drop), so one build stays correct for all of them.  Declared out
    -- here because the tail runs after the closure returns.
    local posCache

    -- Normalize's middle: correct the coordinates that are already on the map.
    local function run_normalize_middle()
        -- De-duplicate rooms that share the same hash.  This must run before
        -- reconcile because duplicate stubs cause phantom occupancy that blocks
        -- _.reconcile_connected_rooms from moving rooms.
        posCache = _.build_pos_cache(areaID)
        result.dedupe = map.dedupe_area_by_hash(areaID, posCache)
        -- Refresh room list after potential deletes
        areaRooms = getAreaRooms(areaID)
        if type(areaRooms) ~= "table" then areaRooms = {} end

        -- Reconcile: BFS-move rooms to match their exits' expected deltas.
        -- Threading posCache also stops each seed below from rebuilding it.
        local moved = 0
        if allRooms then
            echo("Normalising all subgraphs in '" .. areaName_display .. "'...\n")
            local globalVisited = {}
            local seedCount     = 0
            for _i, seedID in ipairs(areaRooms) do
                if not globalVisited[seedID] then
                    local subMoved = _.reconcile_connected_rooms(seedID, maxPasses, maxMoves, nil, globalVisited, posCache)
                    _.flatten_cardinal_connected_rooms(seedID, posCache)
                    moved = moved + (subMoved or 0)
                    seedCount = seedCount + 1
                end
            end
            echo("Normalised across " .. seedCount .. " subgraph" .. (seedCount == 1 and "" or "s") .. ".\n")
        else
            local seedID = currentRoomID and currentRoomID or find_best_seed(areaID)
            if not seedID then
                echo("Cannot normalise: no rooms with exits found in '" .. areaName_display .. "'.\n")
                return false
            end
            echo("Normalising '" .. areaName_display .. "'...\n")
            moved = _.reconcile_connected_rooms(seedID, maxPasses, maxMoves, nil, nil, posCache)
            _.flatten_cardinal_connected_rooms(seedID, posCache)
        end

        result.moved = moved
        return true
    end

    if not with_anchor_policy(anchorRoomID, run_normalize_middle) then return end

    _.finish_layout_repair(areaID, posCache, result, { anchorRoomID = anchorRoomID })

    updateMap()
    emit_layout_report(result)
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
    local totalElevated   = 0
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
            -- One position cache per area, threaded through every pass below
            -- (see the matching comment in normalize_room_layout).
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
                    local subMoved = _.reconcile_connected_rooms(seedID, maxPasses, areaMaxMoves, nil, globalVisited, posCache)
                    _.flatten_cardinal_connected_rooms(seedID, posCache)
                    totalMoved = totalMoved + (subMoved or 0)
                end
            end

            -- Same tail as the single-area command.  No "current room" anchor
            -- across a bulk pass, so real lock flags are respected as before;
            -- the audit is skipped because only cross-area totals are printed
            -- and it would be an O(area) walk per area for numbers never shown.
            local r = _.finish_layout_repair(id, posCache, {},
                { respectRealLocks = true, audit = false })
            totalSnapped    = totalSnapped + (r.snap.snapped or 0)
            totalTranslated = totalTranslated + (r.anchor.translated or 0)
            totalElevated   = totalElevated
                + (r.elevation.rooms_shifted or 0) + (r.elevation.anchored or 0)
            totalSeparated  = totalSeparated + (r.overlap.separated or 0)
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
    if totalElevated > 0 then
        parts[#parts + 1] = totalElevated
            .. " room" .. (totalElevated == 1 and "" or "s") .. " moved onto their elevation"
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

    local areaRooms = getAreaRooms(areaID)

    -- Refuse rather than truncate.  The BFS below is single-pass and derives
    -- every coordinate from the seed outward, so stopping part way does not
    -- leave the area half-repaired — it leaves it half-rebuilt, with the rooms
    -- it reached in the seed's frame and everything else still in the old one,
    -- and the seam between them is a delta mismatch at every crossing.  That is
    -- strictly worse than never having run, and the stages after the BFS then
    -- run over the whole area and bake the split in.
    local maxRooms = tonumber(map.configs.recalculate_max_rooms) or 200000
    local roomCount = type(areaRooms) == "table" and #areaRooms or 0
    if roomCount > maxRooms then
        local areaLabel = _.get_area_name_by_id(areaID) or ("area #" .. tostring(areaID))
        cecho(string.format(
            "<yellow>Cannot recalculate: '%s' has %d rooms, above the %d this command "
            .. "can rebuild in one pass. A partial rebuild would split the area across "
            .. "two coordinate frames, which is worse than leaving it alone.\n"
            .. "Use 'map normalize' here — it repairs incrementally and can be run "
            .. "repeatedly — or split the area into smaller ones first.\n<reset>",
            areaLabel, roomCount, maxRooms))
        return
    end

    -- Strip self-loop exits so BFS does not traverse them.
    local result    = {
        self_loops = type(areaRooms) == "table" and _.strip_self_loop_exits(areaRooms) or 0,
        area_merge = areaMergeResult,
    }

    -- Only the room the recalculation starts from is pinned; any other room
    -- (locked or not) may be repositioned so the BFS can rebuild the whole
    -- area consistently outward from here. Mirrors map normalize's anchor
    -- behaviour (see with_single_locked_anchor above).
    local movedCount, nudgeCount, deletedPlaceholderCount = 0, 0, 0

    -- Recalculate's middle: throw the existing coordinates away and derive new
    -- ones by walking out from the seed.
    local function run_recalculate_middle()
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
    -- Backstop only.  The area-size check above is what actually keeps a rebuild
    -- from truncating; this catches a queue that grows past the room count
    -- anyway, which would mean the exit graph is feeding the BFS rooms it has
    -- already placed and something is badly wrong with the data.
    local MAX_BFS_ROOMS = maxRooms

    while qHead <= #queue do
        if qHead > MAX_BFS_ROOMS then
            echo("[map recalculate] BFS exceeded " .. MAX_BFS_ROOMS
                .. " rooms and was stopped; the area layout is left partly rebuilt.\n")
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
                            -- No cache of our own here (occupancy lives in the
                            -- `occupied` table above), but the write still has to
                            -- reach the long-lived one Core.lua holds.
                            _.set_room_coordinates(targetID, tx, ty, tz)
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

    end -- run_recalculate_middle

    with_single_locked_anchor(seedID, run_recalculate_middle)

    -- The repositioned count is the headline rather than one clause among many,
    -- which is how this command has always announced itself; result.moved is
    -- left unset so it is not also listed inside the parentheses.
    result.nudged               = nudgeCount
    result.placeholders_removed = deletedPlaceholderCount
    result.headline             = "Topology recalculation repositioned "
        .. count(movedCount, "room")

    -- The BFS above writes coordinates through no cache of its own (occupancy
    -- lives in its `occupied` table), so the tail builds one over the finished
    -- positions.  The elevation pass inside it is what stops the rebuild from
    -- inheriting whatever plane the seed happened to be sitting on: every other
    -- z here is the seed's plus a walked shift, and one pass has no second
    -- chance to notice that the starting point was wrong.
    local posCache = _.build_pos_cache(areaID)
    _.finish_layout_repair(areaID, posCache, result, { anchorRoomID = seedID })

    updateMap()
    emit_layout_report(result)
end
