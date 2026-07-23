-- Mapping Script — Commands
-- Public map.* commands, speedwalk/autowalk, context menu, event registrations.

map                            = map or {}
map._                          = map._ or {}
local _                        = map._

-- defaults for the 'map' alias (used in show_help)
local defaults                 = {
    reconcile_max_passes = map.configs.reconcile_deep_max_passes,
    reconcile_max_moves  = map.configs.reconcile_deep_max_moves,
}

-- Underworld entrance marker character
local UNDERWORLD_ENTRANCE_CHAR = "\226\140\130" -- ⌂ (U+2302)

-- Direction check used by check_doors (speedwalk)
local verticalDirs             = { u = true, up = true, d = true, down = true }

-- --------------------------------------------------------------------------
-- Trim helper (local to this file)
-- --------------------------------------------------------------------------

local function trim_whitespace(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function copy_selected_rooms(roomIDs)
    if type(roomIDs) ~= "table" then return {} end
    local copied = {}
    for _, roomID in ipairs(roomIDs) do
        if type(roomID) == "number" and roomID > 0 then
            copied[#copied + 1] = roomID
        end
    end
    return copied
end

-- --------------------------------------------------------------------------
-- POI commands
-- --------------------------------------------------------------------------

-- --------------------------------------------------------------------------
-- Lock / unlock the current room.  Locked rooms are pinned in place: the
-- layout/rebuild passes skip them, so manually-positioned rooms survive
-- subsequent room updates. (`map normalize` temporarily treats only the
-- current room as pinned so repair can spread out from your position.)
-- --------------------------------------------------------------------------
function map.lock_current_room()
    local id = _.current_player_room_id and _.current_player_room_id() or nil
    if not id then
        echo("map lock: current room is unknown.\n")
        return
    end
    _.set_room_locked(id, true)
    local x, y, z = getRoomCoordinates(id)
    echo(string.format("Locked room %d at (%s,%s,%s).\n",
        id, tostring(x), tostring(y), tostring(z)))
    updateMap()
end

function map.unlock_current_room()
    local id = _.current_player_room_id and _.current_player_room_id() or nil
    if not id then
        echo("map unlock: current room is unknown.\n")
        return
    end
    _.set_room_locked(id, false)
    echo("Unlocked room " .. id .. ".\n")
    updateMap()
end

function map.set_poi(roomID)
    roomID = roomID or _.get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot set POI: current room is unknown.\n")
        return
    end
    local terrain = _.get_room_terrain_name(roomID)
    -- Preserve the original terrain so remove_poi can restore it later.
    -- If the room has no terrain (e.g. a placeholder), skip the save.
    if type(terrain) == "string" and terrain ~= "" then
        setRoomUserData(roomID, "terrain", terrain)
    end
    setRoomChar(roomID, "#")
    _.apply_room_environment(roomID, "Inside")
    updateMap()
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") marked as POI (#).\n")
end

function map.remove_poi(roomID)
    roomID = roomID or _.get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot remove POI: current room is unknown.\n")
        return
    end
    setRoomChar(roomID, "")
    local terrain = _.get_room_terrain_name(roomID)
    if type(terrain) == "string" and terrain ~= "" then
        _.apply_room_environment(roomID, terrain)
    end
    updateMap()
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") POI marker removed.\n")
end

function map.toggle_poi_for_selected_room(event, action, ...)
    local roomID = _.get_selected_map_room and _.get_selected_map_room() or nil
    if not roomID then
        echo("Select a room on the mapper, then right-click it to toggle its POI marker.\n")
        return
    end

    if getRoomChar(roomID) == "#" then
        map.remove_poi(roomID)
    else
        map.set_poi(roomID)
    end
end

-- --------------------------------------------------------------------------
-- Underworld entrance commands
-- --------------------------------------------------------------------------

function map.set_underworld_entrance(roomID)
    roomID = roomID or _.get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot set underworld entrance: current room is unknown.\n")
        return
    end
    local terrain = _.get_room_terrain_name(roomID)
    if type(terrain) == "string" and terrain ~= "" then
        setRoomUserData(roomID, "terrain", terrain)
    end
    setRoomChar(roomID, UNDERWORLD_ENTRANCE_CHAR)
    _.apply_room_environment(roomID, "light forest")
    updateMap()
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") marked as underworld entrance.\n")
end

function map.remove_underworld_entrance(roomID)
    roomID = roomID or _.get_current_area_context()
    if not roomID or roomID < 1 then
        echo("Cannot remove underworld entrance: current room is unknown.\n")
        return
    end
    setRoomChar(roomID, "")
    local terrain = _.get_room_terrain_name(roomID)
    if type(terrain) == "string" and terrain ~= "" then
        _.apply_room_environment(roomID, terrain)
    end
    updateMap()
    echo("Room " .. roomID .. " (" .. (getRoomName(roomID) or "unknown") .. ") underworld entrance removed.\n")
end

function map.toggle_underworld_entrance_for_selected_room(event, action, ...)
    local roomID = _.get_selected_map_room and _.get_selected_map_room() or nil
    if not roomID then
        echo("Select a room on the mapper, then right-click it to toggle its underworld entrance marker.\n")
        return
    end

    if getRoomChar(roomID) == UNDERWORLD_ENTRANCE_CHAR then
        map.remove_underworld_entrance(roomID)
    else
        map.set_underworld_entrance(roomID)
    end
end

-- --------------------------------------------------------------------------
-- Area display name
-- --------------------------------------------------------------------------

function map.set_current_area_display_name(newName)
    local cleanName                 = trim_whitespace(newName)
    local _roomID, areaID, areaName = _.get_current_area_context()
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
        local _, currentAreaID = _.get_current_area_context()
        areaID = currentAreaID
    end

    if type(areaID) == "number" and areaID > 0 then
        local displayName = map.configs.area_display_names[tostring(areaID)]
        if type(displayName) == "string" and displayName ~= "" then
            return displayName
        end

        local fallbackAreaName = _.get_area_name_by_id(areaID)
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
    map.configs.area_ids_by_gmcp = {}

    local areas = getAreaTable()
    if type(areas) == "table" then
        local removed = 0
        for name, id in pairs(areas) do
            local savedKey = getAreaUserData(id, "gmcp_area_key")
            if type(savedKey) == "string" and savedKey ~= "" then
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

-- --------------------------------------------------------------------------
-- Diagnostics
-- --------------------------------------------------------------------------

function map.test_normalize_determinism(numRuns)
    numRuns = numRuns or 5

    local roomID = getRoomIDbyHash(map.room_info.vnum)
    if roomID < 1 then
        echo("Cannot test: current room is unknown.\n")
        return
    end

    local snapshots = {}
    echo("Running map normalize " .. numRuns .. " times to test determinism...\n")

    for runNum = 1, numRuns do
        map.normalize_room_layout()
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

    echo("\nComparing snapshots...\n")
    local allMatch      = true
    local firstSnapshot = snapshots[1]

    for runNum = 2, numRuns do
        local currentSnapshot = snapshots[runNum]
        local differences     = 0

        for id, coords in pairs(firstSnapshot) do
            local currentCoords = currentSnapshot[id]
            if not currentCoords then
                echo("  Room " .. id .. " missing in run " .. runNum .. "!\n")
                differences = differences + 1
                allMatch    = false
            elseif coords.x ~= currentCoords.x or coords.y ~= currentCoords.y or coords.z ~= currentCoords.z then
                echo("  Room " .. id .. " differs in run " .. runNum .. ": (" ..
                    coords.x .. "," .. coords.y .. "," .. coords.z .. ") vs (" ..
                    currentCoords.x .. "," .. currentCoords.y .. "," .. currentCoords.z .. ")\n")
                differences = differences + 1
                allMatch    = false
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

-- --------------------------------------------------------------------------
-- Placeholder cleanup
-- --------------------------------------------------------------------------

-- Deletes placeholder rooms in the current (or named) area that are either:
--   (a) at the same map position as a real non-placeholder room, OR
--   (b) orphaned — no non-placeholder room in the area has an exit leading to them.
function map.clean_placeholders(areaNameArg, silent)
    if type(deleteRoom) ~= "function" then
        echo("Error: deleteRoom is not available in this Mudlet version.\n")
        return
    end
    if type(_.is_placeholder) ~= "function" then
        echo("Error: _.is_placeholder is not loaded yet.\n")
        return
    end

    local areaID
    if type(areaNameArg) == "number" and areaNameArg > 0 then
        areaID = areaNameArg
    elseif type(areaNameArg) == "string" and areaNameArg ~= "" then
        local areas = getAreaTable()
        if type(areas) == "table" then
            for name, id in pairs(areas) do
                if string.lower(name) == string.lower(areaNameArg) then
                    areaID = id; break
                end
            end
        end
        if not areaID then
            echo("Cannot find area: " .. areaNameArg .. "\n")
            return
        end
    else
        local _, currentAreaID = _.get_current_area_context()
        areaID = currentAreaID
        if not areaID then
            echo("Cannot determine current area. Move to a room first or specify an area name.\n")
            return
        end
    end

    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then
        echo("Cannot get rooms for area.\n")
        return
    end

    -- Build reverse-exit index and occupancy in one pass:
    --   reverseExits[targetID] = true if any real room exits to targetID
    --   posHasReal[key] = true if any real room occupies (x,y,z)
    local reverseExits = {}
    local posHasReal = {}
    local placeholderPosByID = {}
    local placeholders = {}
    for _k, rid in ipairs(rooms) do
        local isPlaceholder = _.is_placeholder(rid)

        local x, y, z = getRoomCoordinates(rid)
        if x ~= nil then
            local pkey = tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
            if isPlaceholder then
                placeholderPosByID[rid] = pkey
            else
                posHasReal[pkey] = true
            end
        end

        if isPlaceholder then
            placeholders[#placeholders + 1] = rid
        else
            local srcExits = getRoomExits(rid)
            if type(srcExits) == "table" then
                for _k2, target in pairs(srcExits) do
                    local targetID = tonumber(target) or target
                    reverseExits[targetID] = true
                end
            end
        end
    end

    local deletedCount = 0
    for _k, rid in ipairs(placeholders) do
        local shouldDelete = false
        -- (a) positional collision with a real room
        local pkey = placeholderPosByID[rid]
        if pkey and posHasReal[pkey] then
            shouldDelete = true
        end
        -- (b) orphaned: no non-placeholder room in the area exits to this one
        if not shouldDelete and not reverseExits[rid] then
            shouldDelete = true
        end
        if shouldDelete then
            deleteRoom(rid)
            deletedCount = deletedCount + 1
        end
    end

    if deletedCount > 0 and not silent then updateMap() end
    if not silent then
        local areaDisplayName = _.get_area_name_by_id(areaID) or tostring(areaID)
        echo("Deleted " .. deletedCount .. " placeholder room"
            .. (deletedCount == 1 and "" or "s")
            .. " in area '" .. areaDisplayName .. "'.\n")
    end
    return deletedCount
end

-- --------------------------------------------------------------------------
-- Help
-- --------------------------------------------------------------------------

function map.show_help()
    echo("Map commands:\n\n")
    echo("  map help\n")
    echo("    Show this help text.\n\n")
    echo("  map normalize [maxPasses maxMoves]\n")
    echo("    Safe incremental layout repair for the current area.\n")
    echo("    1) Removes self-loop exits (exits pointing back to the same room — always a data bug).\n")
    echo("    2) De-duplicates rooms sharing the same hash (merges stubs into the canonical room,\n")
    echo("       preserving all exits and user data). Must run before reconcile to clear phantom occupants.\n")
    echo("    3) Reconciles connected exits: walks the exit graph and gently moves rooms whose coordinates\n")
    echo("       disagree with their exit offsets, skipping rooms that can't move due to collisions.\n")
    echo("    4) Flattens cardinally connected rooms to the current room's z-level.\n")
    echo("    5) Snaps in-area up/down room pairs to exact ±1 z-offsets (fixes sky-room horizontal drift).\n")
    echo("    6) Aligns each connected sub-graph to the game's coordinate frame using the\n")
    echo("       user_data.coord values stored during room capture. Sub-graphs with no coord anchor\n")
    echo("       remain in Mudlet-relative space and are reported.\n")
    echo("    7) Reports remaining anomalies by category (cyclic mismatches, shared-target bugs, etc.).\n")
    echo("    Manual coordinate tweaks are preserved; normalize pins the current room and\n")
    echo("    allows other rooms to move so the repair can spread outward from your location.\n")
    echo("    Defaults: maxPasses=" ..
        map.configs.reconcile_deep_max_passes .. ", maxMoves=" .. map.configs.reconcile_deep_max_moves .. "\n")
    echo("    Example: map normalize 5 500\n\n")
    echo("    When to use: start here. Safe for day-to-day drift and minor mismatches.\n")
    echo("    Use 'map recalculate' instead when the layout is fundamentally broken (e.g. two separately\n")
    echo("    mapped groups were linked by exits — normalize cannot evict rooms that are in the way).\n\n")
    echo("  map dedupe\n")
    echo("    Shorthand for 'map normalize': de-dupes and aligns the current area.\n\n")
    echo("  map dedupe-all\n")
    echo("    De-dupe and align all areas (same as 'map normalize-all-areas').\n\n")
    echo("  map area-name [new name]\n")
    echo("    Show or set a custom display name for the current area.\n\n")
    echo("  map clear-area-cache\n")
    echo("    Clear the GMCP area cache and remove stale area-key associations.\n")
    echo("    Use this when rooms appear in the wrong area. Re-enter rooms afterwards to rebuild.\n\n")
    echo("  map export\n")
    echo("    Export the visually selected rooms to the clipboard as JSON for sharing or troubleshooting.\n\n")
    echo("  map fix-selected-layout\n")
    echo("    Repair obvious bad exits in the selected rooms, then run a local layout reconcile pass.\n\n")
    echo("  Mapper right-click travel\n")
    echo("    Select or right-click a room in the mapper, then choose Auto walk to selected room.\n\n")
    echo("  stop\n")
    echo("    Stop the current auto walk. If no auto walk is active, sends 'stop' to the game.\n\n")
    echo("  Mapper right-click POI\n")
    echo("    Select or right-click a terrain-mapped room, then choose Toggle POI on selected room.\n\n")
    echo("  map auto-reconcile\n")
    echo("    Automatic room repositioning is disabled.\n")
    echo("    This command is kept only for compatibility; use 'map normalize' to reposition manually.\n\n")
    echo("  map apply-terrain\n")
    echo("    Apply the current room's terrain type to all unset rooms in the current area.\n")
    echo("    Rooms with no environment (env -1 or 0) inherit the current room's terrain color and type.\n")
    echo("    Rooms that already have an environment but no stored terrain userdata get it back-filled.\n")
    echo("    Only works when the current room's terrain is an outdoor forced-z type (plains, forest, etc).\n\n")
    echo("  map recalculate\n")
    echo("    Destructive full layout rebuild from the current room.\n")
    echo("    1) Removes self-loop exits (same as normalize).\n")
    echo("    2) Merges duplicate areas that share the same inferred area-vnum key.\n")
    echo("    3) Rebuilds all room coordinates from scratch via BFS from the current room.\n")
    echo("       Each room is placed at parent-coords + exit-direction; first BFS path wins.\n")
    echo("       Rooms that land on an occupied position are nudged to the nearest free spot.\n")
    echo("    4) Underground rooms (caves, tunnels) are placed on a separate z-level automatically.\n")
    echo("    5) Snaps in-area up/down pairs that BFS didn't align (unreachable rooms, etc.).\n")
    echo("    6) Removes stale BFS placeholder stubs; reports anomalies by category.\n")
    echo("    Pinned/locked rooms are not moved; their position anchors surrounding rooms.\n")
    echo("    More thorough than 'map normalize' — will displace any room that's in the way.\n")
    echo("    When to use: when large groups of rooms have fundamentally wrong coordinates,\n")
    echo("    e.g. two independently mapped groups linked by exits, or vertical stubs at z:0.\n")
    echo("    Use 'map normalize' first for safer, incremental repair.\n\n")
    echo("  map set poi\n")
    echo("    Set the current room's symbol to '#' and apply the Inside background color.\n")
    echo("    Useful for marking points of interest (shops, quest givers, etc.) on the map.\n\n")
    echo("  map clean-placeholders [area name]\n")
    echo("    Delete placeholder rooms whose map position overlaps a real room in the current (or named) area.\n")
    echo("    Useful for cleaning up stale pre-visit stubs after using 'map recalculate' or 'map link-room'.\n\n")
    echo("  map remove poi\n")
    echo("    Remove the POI marker from the current room and restore its original terrain color.\n\n")
end

-- --------------------------------------------------------------------------
-- Terrain / export commands
-- --------------------------------------------------------------------------

function map.apply_area_terrain()
    local roomID, areaID, areaName = _.get_current_area_context()
    if not areaID then
        echo("Cannot apply terrain: current area is unknown.\n")
        return
    end

    local currentTerrain = _.normalize_terrain_name(map.room_info.terrain)
    if not currentTerrain or _.forced_z_by_terrain_name[currentTerrain] == nil then
        echo("Cannot apply terrain: current room's terrain '" ..
            tostring(map.room_info.terrain) .. "' is not a forced-z outdoor type.\n")
        return
    end

    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" then
        echo("No rooms found in area '" .. (areaName or ("#" .. areaID)) .. "'.\n")
        return
    end

    -- Use the pre-built reverse lookup from Data.lua instead of rebuilding per call.
    local envToTerrain      = _.envID_to_terrain or {}

    local envApplied        = 0
    local terrainBackfilled = 0

    for _, rid in pairs(rooms) do
        local envID         = getRoomEnv(rid)
        local storedTerrain = getRoomUserData(rid, "terrain")

        if envID == -1 or envID == 0 then
            _.apply_room_environment(rid, currentTerrain)
            setRoomUserData(rid, "terrain", currentTerrain)
            envApplied = envApplied + 1
        elseif type(storedTerrain) ~= "string" or storedTerrain == "" then
            local reverseName = envToTerrain[envID]
            if reverseName then
                setRoomUserData(rid, "terrain", reverseName)
                terrainBackfilled = terrainBackfilled + 1
            end
        end
    end

    -- Second pass: sky rooms inherit the env colour of the first non-sky room
    -- directly beneath them (same x,y, decreasing z).  The stored terrain
    -- user-data stays "sky"; we only recolour for visual clarity.
    local skySpec       = _.terrain_types and _.terrain_types["sky"]
    local skyEnvID      = skySpec and skySpec.id
    local skyRecoloured = 0
    if skyEnvID then
        -- Build an (x,y,z) -> roomID lookup across the area.
        local posByKey = {}
        for _i, rid in pairs(rooms) do
            local x, y, z = getRoomCoordinates(rid)
            if x ~= nil then
                posByKey[x .. "," .. y .. "," .. z] = rid
            end
        end

        for _i, rid in pairs(rooms) do
            if getRoomEnv(rid) == skyEnvID then
                local x, y, z = getRoomCoordinates(rid)
                if x ~= nil then
                    local inheritedEnv
                    for dz = 1, 50 do
                        local belowID = posByKey[x .. "," .. y .. "," .. (z - dz)]
                        if belowID then
                            local belowEnv = getRoomEnv(belowID)
                            if type(belowEnv) == "number"
                                and belowEnv > 0
                                and belowEnv ~= skyEnvID then
                                inheritedEnv = belowEnv
                                break
                            end
                        end
                    end
                    if inheritedEnv and inheritedEnv ~= getRoomEnv(rid) then
                        setRoomEnv(rid, inheritedEnv)
                        skyRecoloured = skyRecoloured + 1
                    end
                end
            end
        end
    end

    updateMap()
    echo("Area '" .. (areaName or ("#" .. areaID)) .. "': applied terrain to " ..
        envApplied .. " unset room" .. (envApplied == 1 and "" or "s") ..
        ", back-filled terrain data on " .. terrainBackfilled .. " room" ..
        (terrainBackfilled == 1 and "" or "s") ..
        ", recoloured " .. skyRecoloured .. " sky room" ..
        (skyRecoloured == 1 and "" or "s") .. " from below.\n")
end

function map.export_rooms()
    local selection = getMapSelection()
    local roomIDs   = selection and selection.rooms
    if type(roomIDs) ~= "table" or #roomIDs == 0 then
        echo("No rooms selected. Select rooms on the mapper first, then run 'map export'.\n")
        return
    end

    local result = {}

    local function build_exit_details(roomID, roomX, roomY, roomZ, exits)
        if type(exits) ~= "table" then return nil end

        local details = {}
        for rawDir, targetID in pairs(exits) do
            if type(targetID) == "string" then
                targetID = tonumber(targetID)
            end
            if type(targetID) == "number" and targetID > 0 then
                local dirName = type(rawDir) == "number"
                    and (_.stubmapFlipped[rawDir] or tostring(rawDir)) or rawDir
                local targetX, targetY, targetZ = getRoomCoordinates(targetID)
                local targetAreaID = getRoomArea(targetID)

                local delta = nil
                if roomX ~= nil and targetX ~= nil then
                    delta = {
                        x = targetX - roomX,
                        y = targetY - roomY,
                        z = targetZ - roomZ,
                    }
                end

                local expected = nil
                local shift = _.get_shift_for_exit_key and _.get_shift_for_exit_key(dirName) or nil
                if type(shift) == "table" then
                    expected = { x = shift[1], y = shift[2], z = shift[3] }
                end

                local anomalies = {}
                if targetID == roomID then
                    anomalies[#anomalies + 1] = "self_loop"
                end
                if targetX == nil then
                    anomalies[#anomalies + 1] = "missing_target_coords"
                end
                if expected and delta and (expected.x ~= delta.x or expected.y ~= delta.y or expected.z ~= delta.z) then
                    anomalies[#anomalies + 1] = "delta_mismatch"
                end
                if type(targetAreaID) == "number" and targetAreaID ~= getRoomArea(roomID) then
                    anomalies[#anomalies + 1] = "cross_area_exit"
                end

                details[#details + 1] = {
                    direction = dirName,
                    target_id = targetID,
                    target_hash = getRoomHashByID and getRoomHashByID(targetID) or nil,
                    target_name = getRoomName(targetID),
                    target_area_id = targetAreaID,
                    target_area_name = _.get_area_name_by_id(targetAreaID),
                    target_coords = (targetX ~= nil) and { x = targetX, y = targetY, z = targetZ } or nil,
                    expected_delta = expected,
                    actual_delta = delta,
                    anomalies = (#anomalies > 0) and anomalies or nil,
                }
            end
        end

        table.sort(details, function(a, b)
            return tostring(a.direction) < tostring(b.direction)
        end)
        return (#details > 0) and details or nil
    end

    for _i, roomID in ipairs(roomIDs) do
        local areaID       = getRoomArea(roomID)
        local x, y, z      = getRoomCoordinates(roomID)
        local exits        = getRoomExits(roomID)
        local specialExits = getSpecialExitsSwap(roomID)
        local doors        = getDoors(roomID)
        local userData     = getAllRoomUserData(roomID)

        local namedExits   = {}
        if type(exits) == "table" then
            for k, v in pairs(exits) do
                local dirName = type(k) == "number"
                    and (_.stubmapFlipped[k] or tostring(k)) or k
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
            area_name     = _.get_area_name_by_id(areaID),
            environment   = getRoomEnv(roomID),
            exits         = namedExits,
            exit_details  = build_exit_details(roomID, x, y, z, exits),
            special_exits = (type(specialExits) == "table" and next(specialExits) ~= nil) and specialExits or nil,
            doors         = (type(doors) == "table" and next(doors) ~= nil) and doors or nil,
            user_data     = (type(userData) == "table" and next(userData) ~= nil) and userData or nil,
        }
    end

    local json = yajl.to_string(result)
    setClipboardText(json)
    echo("Exported " .. #result .. " room" .. (#result == 1 and "" or "s") .. " to clipboard.\n")
end

function map.fix_selected_layout()
    local selection = getMapSelection()
    local roomIDs = selection and selection.rooms
    if type(roomIDs) ~= "table" or #roomIDs == 0 then
        echo("No rooms selected. Select rooms on the mapper first, then run 'map fix-selected-layout'.\n")
        return
    end

    local selectedSet = {}
    local selected = {}
    local seedArea
    local skippedArea = 0
    for _, rid in ipairs(roomIDs) do
        if type(rid) == "number" and rid > 0 then
            local ridArea = getRoomArea(rid)
            if not seedArea then
                seedArea = ridArea
            end
            if ridArea == seedArea then
                selectedSet[rid] = true
                selected[#selected + 1] = rid
            else
                skippedArea = skippedArea + 1
            end
        end
    end

    if #selected == 0 then
        echo("Cannot repair selection: no valid rooms were found in one area.\n")
        return
    end

    local removedSelf = 0
    local removedCrossMismatch = 0
    local addedReverse = 0

    for _, rid in ipairs(selected) do
        local roomArea = getRoomArea(rid)
        local roomX, roomY, roomZ = getRoomCoordinates(rid)
        local exits = getRoomExits(rid)

        if type(exits) == "table" then
            for rawDir, targetID in pairs(exits) do
                if type(targetID) == "string" then
                    targetID = tonumber(targetID)
                end
                if type(targetID) == "number" and targetID > 0 then
                    local dir = _.normalize_exit_direction and _.normalize_exit_direction(rawDir) or rawDir
                    local dirKey = dir or rawDir

                    if targetID == rid then
                        setExit(rid, -1, dirKey)
                        removedSelf = removedSelf + 1
                    else
                        local targetArea = getRoomArea(targetID)
                        local targetX, targetY, targetZ = getRoomCoordinates(targetID)
                        local shift = _.get_shift_for_exit_key and _.get_shift_for_exit_key(dir) or nil

                        local mismatch = false
                        if type(shift) == "table"
                            and roomX ~= nil and targetX ~= nil then
                            mismatch = (targetX - roomX) ~= shift[1]
                                or (targetY - roomY) ~= shift[2]
                                or (targetZ - roomZ) ~= shift[3]
                        end

                        if type(targetArea) == "number"
                            and type(roomArea) == "number"
                            and targetArea ~= roomArea
                            and mismatch then
                            setExit(rid, -1, dirKey)
                            removedCrossMismatch = removedCrossMismatch + 1
                        elseif selectedSet[targetID] then
                            local reverse = _.reverse_move_vectors and _.reverse_move_vectors[dir]
                            if reverse then
                                local back = _.get_room_exit_target and _.get_room_exit_target(targetID, reverse) or nil
                                if back ~= rid then
                                    setExit(targetID, rid, reverse)
                                    addedReverse = addedReverse + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local moved = 0
    local seedID = selected[1]
    if _.reconcile_connected_rooms and seedID then
        moved = _.reconcile_connected_rooms(seedID,
            map.configs.reconcile_deep_max_passes,
            map.configs.reconcile_deep_max_moves) or 0
    end
    if _.flatten_cardinal_connected_rooms and seedID then
        _.flatten_cardinal_connected_rooms(seedID)
    end

    updateMap()
    echo("Repair complete for " .. #selected .. " selected room" .. (#selected == 1 and "" or "s") .. ".\n")
    echo("  Removed self-loop exits: " .. removedSelf .. "\n")
    echo("  Removed cross-area mismatched exits: " .. removedCrossMismatch .. "\n")
    echo("  Added missing reverse exits: " .. addedReverse .. "\n")
    echo("  Rooms moved by reconcile: " .. (moved or 0) .. "\n")
    if skippedArea > 0 then
        echo("  Skipped " .. skippedArea .. " room" .. (skippedArea == 1 and "" or "s")
            .. " outside the first selected area.\n")
    end
end

-- --------------------------------------------------------------------------
-- Speedwalk / autowalk
-- --------------------------------------------------------------------------

local continue_walk, timerID
local start_autowalk_to_room
local maybe_reevaluate_autowalk -- forward declare; body is defined after compute_autowalk_path

-- Initialise walk state on map.* so these are never nil globals.
map.walking  = map.walking or false
map.walkDirs = map.walkDirs or {}


local function get_active_speedwalk_delay()
    if type(map.walk_settings) == "table" and type(map.walk_settings.delay) == "number" then
        return map.walk_settings.delay
    end
    return map.configs.speedwalk_delay or 0
end

local function get_active_speedwalk_wait()
    if type(map.walk_settings) == "table" and type(map.walk_settings.wait_for_room) == "boolean" then
        return map.walk_settings.wait_for_room
    end
    return map.configs.speedwalk_wait == true
end

local function clear_active_walk_settings()
    map.walk_settings   = nil
    map.last_walk_dir   = nil
    map.autowalk_target = nil
    map.autowalk_dirty  = nil
end

-- Expose so Core.lua's eventHandler can call them
_.get_active_speedwalk_delay = get_active_speedwalk_delay
_.get_active_speedwalk_wait  = get_active_speedwalk_wait

function map.stop_auto_walk()
    if not map.walking then return false end
    map.walking  = false
    map.walkDirs = {}
    clear_active_walk_settings()
    if timerID then
        killTimer(timerID)
        timerID = nil
    end
    echo("Auto walk stopped.\n")
    return true
end

continue_walk = function(new_room)
    if not map.walking then
        clear_active_walk_settings()
        return
    end
    -- Nothing left to walk — clear state without scheduling another timer.
    if #map.walkDirs == 0 then
        map.walking = false
        clear_active_walk_settings()
        return
    end
    -- Re-evaluate route if the map has grown since the last step.
    if map.autowalk_dirty and maybe_reevaluate_autowalk then
        maybe_reevaluate_autowalk()
        if not map.walking then return end
    end
    local wait        = get_active_speedwalk_delay()
    local waitForRoom = get_active_speedwalk_wait()
    if wait > 0 and map.configs.speedwalk_random then
        wait = wait * (1 + math.random(0, 100) / 100)
    end
    if new_room and waitForRoom and wait == 0 then
        new_room = false
    end
    if not new_room then
        local rawDir = table.remove(map.walkDirs, 1)
        -- Record the direction so handle_move can adopt an existing placeholder
        -- whose hash doesn't yet match the incoming GMCP vnum.
        local canonDir = _.exitmap and (_.exitmap[rawDir] or rawDir) or rawDir
        map.last_walk_dir = canonDir
        send(rawDir)
        if #map.walkDirs == 0 then
            map.walking = false
            clear_active_walk_settings()
        end
    end
    if map.walking and (not waitForRoom or (waitForRoom and wait > 0)) then
        if timerID then killTimer(timerID) end
        timerID = tempTimer(wait, function() continue_walk() end)
    end
end

-- Expose for Core's event handler
_.continue_walk = continue_walk

local function check_doors(roomID, exits)
    if type(exits) == "string" then exits = { exits } end
    local statuses = {}
    local doors    = getDoors(roomID)
    if type(doors) ~= "table" then return false end
    local dir
    for k, v in pairs(exits) do
        dir = _.short[k] or _.short[v]
        if verticalDirs[dir] then dir = _.exitmap[dir] end
        if not doors[dir] or doors[dir] == 0 then
            return false
        else
            statuses[dir] = doors[dir]
        end
    end
    return statuses
end

function map.speedwalk(roomID, walkPath, walkDirs, options)
    local currentRoomID = _.get_current_area_context()
    if not currentRoomID or currentRoomID < 1 then
        echo("Cannot speedwalk: current room is unknown.\n")
        if type(map.room_info) == "table" and type(map.room_info.vnum) == "string" then
            echo("  Debug: vnum=" .. map.room_info.vnum .. ", lookup returned " .. tostring(getRoomIDbyHash(map.room_info.vnum)) .. "\n")
        else
            echo("  Debug: map.room_info.vnum is not available\n")
        end
        if type(getPlayerRoom) == "function" then
            echo("  Debug: getPlayerRoom()=" .. tostring(getPlayerRoom()) .. "\n")
        end
        return
    end

    options            = options or {}
    local providedPath = type(walkPath) == "table" and type(walkDirs) == "table" and #walkPath > 0
    roomID             = roomID or (providedPath and walkPath[#walkPath]) or speedWalkPath[#speedWalkPath]
    if type(roomID) ~= "number" or roomID < 1 then
        echo("Cannot speedwalk: target room is unknown.\n")
        return
    end

    if providedPath then
        local sourcePath = walkPath
        local sourceDirs = walkDirs
        walkPath = {}
        walkDirs = {}
        for i, v in ipairs(sourcePath) do walkPath[i] = v end
        for i, v in ipairs(sourceDirs) do walkDirs[i] = v end
    else
        getPath(currentRoomID, roomID)
        if #speedWalkPath == 0 then
            echo("No path to chosen room found.\n")
            return
        end
        walkPath = {}
        walkDirs = {}
        for i, v in ipairs(speedWalkPath) do walkPath[i] = v end
        for i, v in ipairs(speedWalkDir) do walkDirs[i] = v end
    end

    if #walkPath == 0 or #walkDirs == 0 then
        echo("No path to chosen room found.\n")
        return
    end
    table.insert(walkPath, 1, currentRoomID)

    local k = 1
    repeat
        local id, dir = walkPath[k], walkDirs[k]
        if _.exitmap[dir] or _.short[dir] then
            local mappedDir = _.exitmap[dir] or dir
            local door      = check_doors(id, mappedDir)
            local status    = door and door[mappedDir]
            if status and status > 1 then
                if status == 3 then
                    table.insert(walkPath, k, id)
                    table.insert(walkDirs, k, "unlock " .. (_.exitmap[dir] or dir))
                    k = k + 1
                end
                table.insert(walkPath, k, id)
                table.insert(walkDirs, k, "open " .. (_.exitmap[dir] or dir))
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

    map.walking       = true
    map.walk_settings = {
        wait_for_room = options.wait_for_room,
        delay         = options.delay,
    }
    if get_active_speedwalk_wait() or get_active_speedwalk_delay() > 0 then
        map.walkDirs = walkDirs
        continue_walk()
    else
        for _, dir in ipairs(walkDirs) do send(dir) end
        map.walking = false
        clear_active_walk_settings()
    end
end

function doSpeedWalk()
    if #speedWalkPath == 0 or #speedWalkDir == 0 then
        echo("No path to chosen room found.\n")
        return
    end

    local targetRoomID = tonumber(speedWalkPath[#speedWalkPath])
    if not targetRoomID or targetRoomID < 1 then
        echo("No path to chosen room found.\n")
        return
    end

    map.autowalk_target = targetRoomID
    map.speedwalk(targetRoomID, speedWalkPath, speedWalkDir, { wait_for_room = true, delay = 0 })
end

-- --------------------------------------------------------------------------
-- Autowalk helpers
-- --------------------------------------------------------------------------

-- Mudlet's mapper sometimes deselects a room when a right-click misses
-- the room slightly (e.g. clicking just outside the bounds).  By the time
-- the menu event fires, getMapSelection() is empty.  We poll the live
-- selection on a short interval and cache the most recent non-empty value
-- so right-click handlers can fall back to the room the user actually
-- intended to act on.
local read_live_selected_rooms

local function read_live_selected_room()
    local roomIDs = read_live_selected_rooms()
    if type(roomIDs) == "table" and #roomIDs > 0 then
        return roomIDs[1]
    end
    return nil
end

read_live_selected_rooms = function()
    if type(getMapSelection) ~= "function" then return nil end
    local selection = getMapSelection()
    if type(selection) ~= "table" then return nil end
    local roomIDs = copy_selected_rooms(selection.rooms)
    if #roomIDs > 0 then
        return roomIDs
    end
    if type(selection.center) == "number" and selection.center > 0 then
        return { selection.center }
    end
    return nil
end

local function refresh_selected_room_cache()
    local roomIDs = read_live_selected_rooms()
    if type(roomIDs) == "table" and #roomIDs > 0 then
        map.last_selected_rooms = roomIDs
        map.last_selected_room = roomIDs[1]
    end
end

local function get_selected_map_room()
    local roomIDs = read_live_selected_rooms()
    if type(roomIDs) == "table" and #roomIDs > 0 then
        map.last_selected_rooms = roomIDs
        map.last_selected_room = roomIDs[1]
        return roomIDs[1]
    end
    -- Fallback: most recently observed selection (handles right-click misses
    -- that clear the selection before the menu event fires).
    local cached = map.last_selected_room
    if type(cached) == "number" and cached > 0 then return cached end
    return nil
end

local function get_selected_map_rooms()
    local roomIDs = read_live_selected_rooms()
    if type(roomIDs) == "table" and #roomIDs > 0 then
        map.last_selected_rooms = roomIDs
        map.last_selected_room = roomIDs[1]
        return roomIDs
    end

    local cached = copy_selected_rooms(map.last_selected_rooms)
    if #cached > 0 then
        return cached
    end

    local roomID = get_selected_map_room()
    if roomID then
        return { roomID }
    end
    return {}
end

_.refresh_selected_room_cache = refresh_selected_room_cache
_.get_selected_map_room       = get_selected_map_room
_.get_selected_map_rooms      = get_selected_map_rooms

-- Kill any existing timer before (re)creating it so script reloads don't
-- stack orphaned repeating timers on top of each other.
if map.selection_cache_timer_id then
    pcall(killTimer, map.selection_cache_timer_id)
    map.selection_cache_timer_id = nil
end
do
    local ok, timerId = pcall(tempTimer, 0.25, function()
        refresh_selected_room_cache()
    end, true)
    if ok and type(timerId) == "number" then
        map.selection_cache_timer_id = timerId
    end
end

-- Placeholder rooms (env 46, no exits) are created one-directionally by
-- create_neighbors_for_current_room.  Mudlet's getPath cannot route THROUGH
-- them because they have no outgoing exits.  Before running getPath we
-- temporarily add exits between each placeholder and its grid-adjacent
-- neighbours, then remove them immediately after so the map data is not
-- polluted.
--
-- We scan only a padded bounding box via getRoomsByPosition (one call per
-- candidate cell) instead of iterating the entire area, to avoid freezing
-- on large maps.
local PLACEHOLDER_PAD = 5 -- extra tiles of padding around the path bounding box

local function room_at(areaID, x, y, z)
    if type(getRoomsByPosition) ~= "function" then return nil end
    local hit = getRoomsByPosition(areaID, x, y, z)
    if type(hit) == "number" and hit > 0 then return hit end
    if type(hit) == "table" then
        for _i, rid in ipairs(hit) do
            if type(rid) == "number" and rid > 0 then return rid end
        end
    end
    return nil
end

local function add_placeholder_exits(areaID, currentRoomID, targetRoomID)
    local unvisitedID = _.terrain_types["unvisited"] and _.terrain_types["unvisited"].id or 46
    local added       = {}
    if type(setExit) ~= "function" or type(getRoomsByPosition) ~= "function" then
        return added
    end

    local cx, cy, cz = getRoomCoordinates(currentRoomID)
    local tx, ty, tz = getRoomCoordinates(targetRoomID)
    if cx == nil or tx == nil then return added end

    local pad    = PLACEHOLDER_PAD
    local minX   = math.min(cx, tx) - pad
    local maxX   = math.max(cx, tx) + pad
    local minY   = math.min(cy, ty) - pad
    local maxY   = math.max(cy, ty) + pad
    local minZ   = math.min(cz, tz) - 1
    local maxZ   = math.max(cz, tz) + 1

    -- Safety cap: bail if the box is unreasonably large.
    local volume = (maxX - minX + 1) * (maxY - minY + 1) * (maxZ - minZ + 1)
    if volume > 4000 then return added end

    for z = minZ, maxZ do
        for y = minY, maxY do
            for x = minX, maxX do
                local rid = room_at(areaID, x, y, z)
                if rid and getRoomEnv(rid) == unvisitedID then
                    for dir, shift in pairs(_.move_vectors) do
                        local neighbourID = room_at(areaID, x + shift[1], y + shift[2], z + shift[3])
                        if neighbourID then
                            local ex = getRoomExits(rid)
                            if type(ex) ~= "table" or ex[dir] == nil then
                                setExit(rid, neighbourID, dir)
                                added[#added + 1] = { rid, dir }
                            end
                            local revDir = _.reverse_move_vectors[dir]
                            if revDir then
                                local nex = getRoomExits(neighbourID)
                                if type(nex) ~= "table" or nex[revDir] == nil then
                                    setExit(neighbourID, rid, revDir)
                                    added[#added + 1] = { neighbourID, revDir }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return added
end

local function remove_placeholder_exits(added)
    for _i, e in ipairs(added) do
        setExit(e[1], -1, e[2])
    end
end

-- Shared helpers for copying Mudlet's global speedwalk tables and checking
-- whether the found path passes through any POI (#) room.
local function copy_speedwalk_globals()
    local walkPath, walkDirs = {}, {}
    for i, v in ipairs(speedWalkPath) do walkPath[i] = v end
    for i, v in ipairs(speedWalkDir) do walkDirs[i] = v end
    return walkPath, walkDirs
end

local function speedwalk_path_has_poi()
    for _i, rid in ipairs(speedWalkPath) do
        if getRoomChar(rid) == "#" then return true end
    end
    return false
end

local function compute_autowalk_path(currentRoomID, targetRoomID)
    local targetIsPoi = getRoomChar(targetRoomID) == "#"

    -- ----------------------------------------------------------------
    -- Fast path: try getPath with no manipulation at all.
    -- This handles the vast majority of walks (fully-mapped rooms, no
    -- POIs along the route) and skips getAreaRooms and
    -- add_placeholder_exits entirely.
    -- ----------------------------------------------------------------
    getPath(currentRoomID, targetRoomID)
    if #speedWalkPath > 0 and (targetIsPoi or not speedwalk_path_has_poi()) then
        local walkPath, walkDirs = copy_speedwalk_globals()
        return true, walkPath, walkDirs
    end

    -- ----------------------------------------------------------------
    -- Slow path: either no direct path was found (target may be behind
    -- unvisited placeholder rooms) or the direct route runs through
    -- POI rooms and we need to lock them and re-route.
    -- ----------------------------------------------------------------
    local areaID = getRoomArea(currentRoomID)

    local addedExits = (type(areaID) == "number" and areaID > 0)
        and add_placeholder_exits(areaID, currentRoomID, targetRoomID) or {}

    if not targetIsPoi
        and type(getAreaRooms) == "function"
        and type(lockRoom) == "function"
        and type(roomLocked) == "function" then
        local temporarilyLocked = {}
        local areaRooms = (type(areaID) == "number" and areaID > 0) and getAreaRooms(areaID) or {}
        for _i, roomID in ipairs(areaRooms) do
            if type(roomID) == "number"
                and roomID ~= currentRoomID
                and roomID ~= targetRoomID
                and getRoomChar(roomID) == "#"
                and not roomLocked(roomID) then
                lockRoom(roomID, true)
                temporarilyLocked[#temporarilyLocked + 1] = roomID
            end
        end

        local ok       = getPath(currentRoomID, targetRoomID)
        local walkPath = nil
        local walkDirs = nil
        if ok and #speedWalkPath > 0 then
            walkPath, walkDirs = copy_speedwalk_globals()
        end

        for _i, roomID in ipairs(temporarilyLocked) do
            lockRoom(roomID, false)
        end
        remove_placeholder_exits(addedExits)

        return ok and walkPath ~= nil, walkPath, walkDirs
    end

    -- Target is a POI room — no locking needed.
    local ok       = getPath(currentRoomID, targetRoomID)
    local walkPath = nil
    local walkDirs = nil
    if ok and #speedWalkPath > 0 then
        walkPath, walkDirs = copy_speedwalk_globals()
    end
    remove_placeholder_exits(addedExits)
    return ok and walkPath ~= nil, walkPath, walkDirs
end

-- After compute_autowalk_path is in scope we can define the reevaluation logic.
-- This is called from continue_walk when map.autowalk_dirty is true.
maybe_reevaluate_autowalk = function()
    map.autowalk_dirty = false -- clear immediately to avoid re-entrancy
    if map.configs.autowalk_reevaluate == false then return end
    if type(map.autowalk_target) ~= "number" or map.autowalk_target < 1 then return end
    local currentRoomID = _.get_current_area_context()
    if not currentRoomID or currentRoomID < 1 then return end
    if currentRoomID == map.autowalk_target then return end

    local pathFound, newWalkPath, newWalkDirs = compute_autowalk_path(currentRoomID, map.autowalk_target)
    if not pathFound or type(newWalkDirs) ~= "table" or #newWalkDirs == 0 then
        cecho("<red>Autowalk: target no longer reachable, stopping.\n")
        map.stop_auto_walk()
        return
    end
    if #newWalkDirs < #map.walkDirs then
        cecho("<cyan>Autowalk: shorter path found (" .. #map.walkDirs .. " → " .. #newWalkDirs .. " steps).\n")
        map.walkDirs = newWalkDirs
    end
end

start_autowalk_to_room = function(targetRoomID)
    if type(targetRoomID) ~= "number" or targetRoomID < 1 then
        echo("No path to selected room found.\n")
        return false
    end

    local currentRoomID = _.get_current_area_context()
    if not currentRoomID or currentRoomID < 1 then
        echo("Cannot travel: current room is unknown.\n")
        return false
    end

    if currentRoomID == targetRoomID then
        echo("Already at the selected room.\n")
        return false
    end

    local pathFound, walkPath, walkDirs = compute_autowalk_path(currentRoomID, targetRoomID)
    if not pathFound or type(walkPath) ~= "table" or #walkPath == 0 then
        echo("No path to selected room found.\n")
        return false
    end

    map.autowalk_target = targetRoomID
    map.speedwalk(targetRoomID, walkPath, walkDirs, { wait_for_room = true, delay = 0 })
    return true
end

function map.travel_to_selected_room(event, action, ...)
    local targetRoomID = get_selected_map_room()
    if not targetRoomID then
        echo("Select a room on the mapper, then right-click it to travel there.\n")
        return
    end
    local resolvedAction = action
    if action == "alui-mapper-autowalk" then resolvedAction = "autowalk" end
    if resolvedAction == "autowalk" then
        start_autowalk_to_room(targetRoomID)
    else
        echo("Unknown mapper travel action '" .. tostring(action) .. "'.\n")
    end
end

-- --------------------------------------------------------------------------
-- Mapper context menu
-- --------------------------------------------------------------------------

local function register_mapper_context_menu()
    if type(addMapEvent) ~= "function" then return end

    if type(removeMapEvent) == "function" then
        removeMapEvent("alui-mapper-autowalk")
        removeMapEvent("alui-mapper-speedwalk")
        removeMapEvent("alui-mapper-toggle-poi")
        removeMapEvent("alui-mapper-toggle-uw-entrance")
    end
    if type(removeMapMenu) == "function" then
        removeMapMenu("alui-mapper-travel")
    end

    local autoWalkOk, autoWalkErr = addMapEvent(
        "alui-mapper-autowalk",
        "aluiMapperTravel",
        nil,
        "Auto walk to selected room",
        "autowalk"
    )
    local poiOk, poiErr = addMapEvent(
        "alui-mapper-toggle-poi",
        "aluiMapperTogglePoi",
        nil,
        "Toggle POI on selected room"
    )
    local uwOk, uwErr = addMapEvent(
        "alui-mapper-toggle-uw-entrance",
        "aluiMapperToggleUwEntrance",
        nil,
        "Toggle Underworld Entrance"
    )
    if autoWalkOk and poiOk and uwOk then
        map.mapper_context_menu_registered = true
        map.mapper_context_menu_error      = nil
    else
        map.mapper_context_menu_registered = false
        map.mapper_context_menu_error      = autoWalkErr or poiErr or uwErr
    end
end

-- Expose so Core.lua's eventHandler can call it on sysConnectionEvent
_.register_mapper_context_menu = register_mapper_context_menu

map.register_mapper_context_menu = register_mapper_context_menu

-- --------------------------------------------------------------------------
-- Event registrations & initial context menu setup
-- --------------------------------------------------------------------------

register_mapper_context_menu()
registerAnonymousEventHandler("gmcp.Room.Info", "map.eventHandler")
registerAnonymousEventHandler("shiftRoom", "map.eventHandler")
registerAnonymousEventHandler("sysConnectionEvent", "map.eventHandler")

if not map.mapper_travel_menu_handler_registered then
    registerAnonymousEventHandler("aluiMapperTravel", "map.travel_to_selected_room")
    map.mapper_travel_menu_handler_registered = true
end
if not map.mapper_poi_menu_handler_registered then
    registerAnonymousEventHandler("aluiMapperTogglePoi", "map.toggle_poi_for_selected_room")
    map.mapper_poi_menu_handler_registered = true
end
if not map.mapper_uw_entrance_menu_handler_registered then
    registerAnonymousEventHandler("aluiMapperToggleUwEntrance",
        "map.toggle_underworld_entrance_for_selected_room")
    map.mapper_uw_entrance_menu_handler_registered = true
end
