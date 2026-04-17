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

-- --------------------------------------------------------------------------
-- POI commands
-- --------------------------------------------------------------------------

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
    local selection = getMapSelection()
    local roomID    = type(selection) == "table" and selection.center or nil
    if (type(roomID) ~= "number" or roomID < 1) and type(selection) == "table"
        and type(selection.rooms) == "table" then
        roomID = selection.rooms[1]
    end
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
    local selection = getMapSelection()
    local roomID    = type(selection) == "table" and selection.center or nil
    if (type(roomID) ~= "number" or roomID < 1) and type(selection) == "table"
        and type(selection.rooms) == "table" then
        roomID = selection.rooms[1]
    end
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
-- Help
-- --------------------------------------------------------------------------

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
    echo("  map export\n")
    echo("    Export the visually selected rooms to the clipboard as JSON for sharing or troubleshooting.\n\n")
    echo("  Mapper right-click travel\n")
    echo("    Select or right-click a room in the mapper, then choose Auto walk to selected room.\n\n")
    echo("  stop\n")
    echo("    Stop the current auto walk. If no auto walk is active, sends 'stop' to the game.\n\n")
    echo("  Mapper right-click POI\n")
    echo("    Select or right-click a terrain-mapped room, then choose Toggle POI on selected room.\n\n")
    echo("  map auto-reconcile\n")
    echo("    Toggle automatic room repositioning on/off (currently " ..
        (map.configs.auto_reconcile and "ON" or "OFF") .. ").\n")
    echo("    When ON (default), rooms are repositioned each move to keep exit vectors consistent.\n")
    echo("    Turn OFF to prevent shuffling when moving between areas. Use 'map normalize' to reposition manually.\n\n")
    echo("  map apply-terrain\n")
    echo("    Apply the current room's terrain type to all unset rooms in the current area.\n")
    echo("    Rooms with no environment (env -1 or 0) inherit the current room's terrain color and type.\n")
    echo("    Rooms that already have an environment but no stored terrain userdata get it back-filled.\n")
    echo("    Only works when the current room's terrain is an outdoor forced-z type (plains, forest, etc).\n\n")
    echo("  map recalculate\n")
    echo("    Rebuild all room coordinates from scratch using exit topology from the current room.\n")
    echo("    Each room is placed at parent-coords + exit-direction. First BFS path to each room wins.\n")
    echo("    Rooms that would land on an already-occupied position are nudged to the nearest free spot.\n")
    echo("    Underground rooms (caves, tunnels, etc.) are automatically placed on a separate z-level\n")
    echo("    so they don't visually overlap with surface rooms. Use the mapper's z-level selector to\n")
    echo("    switch between surface and underground views.\n")
    echo("    More reliable than normalize when large groups of rooms have badly wrong coordinates\n")
    echo("    (e.g. two independently mapped groups linked by exits, or vertical stubs stuck at z:0).\n")
    echo("    Pinned rooms are not moved; their position is used as an anchor for surrounding rooms.\n\n")
    echo("  map set poi\n")
    echo("    Set the current room's symbol to '#' and apply the Inside background color.\n")
    echo("    Useful for marking points of interest (shops, quest givers, etc.) on the map.\n\n")
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
            _.apply_room_environment(rid, map.room_info.terrain)
            setRoomUserData(rid, "terrain", map.room_info.terrain)
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
            special_exits = (type(specialExits) == "table" and next(specialExits) ~= nil) and specialExits or nil,
            doors         = (type(doors) == "table" and next(doors) ~= nil) and doors or nil,
            user_data     = (type(userData) == "table" and next(userData) ~= nil) and userData or nil,
        }
    end

    local json = yajl.to_string(result)
    setClipboardText(json)
    echo("Exported " .. #result .. " room" .. (#result == 1 and "" or "s") .. " to clipboard.\n")
end

-- --------------------------------------------------------------------------
-- Speedwalk / autowalk
-- --------------------------------------------------------------------------

local continue_walk, timerID

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
    map.walk_settings = nil
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
    local wait        = get_active_speedwalk_delay()
    local waitForRoom = get_active_speedwalk_wait()
    if wait > 0 and map.configs.speedwalk_random then
        wait = wait * (1 + math.random(0, 100) / 100)
    end
    if new_room and waitForRoom and wait == 0 then
        new_room = false
    end
    if not new_room then
        send(table.remove(map.walkDirs, 1))
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
    if #speedWalkPath ~= 0 then
        map.speedwalk(nil, speedWalkPath, speedWalkDir)
    else
        echo("No path to chosen room found.\n")
    end
end

-- --------------------------------------------------------------------------
-- Autowalk helpers
-- --------------------------------------------------------------------------

local function get_selected_map_room()
    local selection = getMapSelection()
    if type(selection) ~= "table" then return nil end
    if type(selection.center) == "number" and selection.center > 0 then
        return selection.center
    end
    if type(selection.rooms) == "table" and type(selection.rooms[1]) == "number"
        and selection.rooms[1] > 0 then
        return selection.rooms[1]
    end
    return nil
end

local function should_avoid_pois_for_autowalk(currentRoomID, targetRoomID)
    return type(_.get_room_terrain_name(currentRoomID)) == "string"
        or type(_.get_room_terrain_name(targetRoomID)) == "string"
        or _.current_room_uses_grid_mode()
end

local function compute_autowalk_path(currentRoomID, targetRoomID)
    if not should_avoid_pois_for_autowalk(currentRoomID, targetRoomID)
        or type(getRooms) ~= "function"
        or type(lockRoom) ~= "function"
        or type(roomLocked) ~= "function" then
        local ok = getPath(currentRoomID, targetRoomID)
        if not ok or #speedWalkPath == 0 then return false, nil, nil end
        local walkPath = {}
        local walkDirs = {}
        for i, v in ipairs(speedWalkPath) do walkPath[i] = v end
        for i, v in ipairs(speedWalkDir) do walkDirs[i] = v end
        return true, walkPath, walkDirs
    end

    local temporarilyLocked = {}
    for roomID, _ in pairs(getRooms()) do
        if type(roomID) == "number"
            and roomID ~= currentRoomID
            and roomID ~= targetRoomID
            and getRoomChar(roomID) == "#"
            and type(_.get_room_terrain_name(roomID)) == "string"
            and not roomLocked(roomID) then
            lockRoom(roomID, true)
            temporarilyLocked[#temporarilyLocked + 1] = roomID
        end
    end

    local ok       = getPath(currentRoomID, targetRoomID)
    local walkPath = nil
    local walkDirs = nil
    if ok and #speedWalkPath > 0 then
        walkPath = {}
        walkDirs = {}
        for i, v in ipairs(speedWalkPath) do walkPath[i] = v end
        for i, v in ipairs(speedWalkDir) do walkDirs[i] = v end
    end

    for _, roomID in ipairs(temporarilyLocked) do
        lockRoom(roomID, false)
    end

    return ok and walkPath ~= nil, walkPath, walkDirs
end

function map.travel_to_selected_room(event, action, ...)
    local targetRoomID = get_selected_map_room()
    if not targetRoomID then
        echo("Select a room on the mapper, then right-click it to travel there.\n")
        return
    end

    local currentRoomID = _.get_current_area_context()
    if not currentRoomID or currentRoomID < 1 then
        echo("Cannot travel: current room is unknown.\n")
        return
    end

    if currentRoomID == targetRoomID then
        echo("Already at the selected room.\n")
        return
    end

    local pathFound, walkPath, walkDirs = compute_autowalk_path(currentRoomID, targetRoomID)
    if not pathFound or type(walkPath) ~= "table" or #walkPath == 0 then
        echo("No path to selected room found.\n")
        return
    end

    local resolvedAction = action
    if action == "alui-mapper-autowalk" then resolvedAction = "autowalk" end

    if resolvedAction == "autowalk" then
        map.speedwalk(targetRoomID, walkPath, walkDirs, { wait_for_room = true, delay = 0 })
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
