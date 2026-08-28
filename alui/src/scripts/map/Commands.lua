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
-- Lock / unlock the current room.  Locked rooms are pinned in place: normal
-- per-move layout logic skips them, so manually-positioned rooms survive
-- subsequent room updates. (`map normalize` and `map recalculate` ignore
-- this flag for every room except the one the process starts from, so repair
-- can spread out from your position without being blocked by old pins.)
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

-- Show or set whether an arrival positions the room relative to the room the
-- player just left.  See map.configs.place_from_previous in Data.lua.
function map.set_follow_previous(arg)
    local setting = type(arg) == "string" and string.lower(arg) or nil
    if setting == "on" or setting == "true" then
        map.configs.place_from_previous = true
    elseif setting == "off" or setting == "false" then
        map.configs.place_from_previous = false
    elseif setting ~= nil then
        echo("map follow: expected 'on' or 'off'.\n")
        return
    end
    if map.configs.place_from_previous == false then
        echo("map follow is off: rooms keep the coordinates they already have, and only\n")
        echo("  the exit-vote passes (and 'map normalize') may move them.\n")
    else
        echo("map follow is on: each room you walk into is positioned one step from the room\n")
        echo("  you left, in the direction you walked.\n")
    end
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

-- Shared by map test-normalize / map test-recalculate: runs `mutateFn` numRuns
-- times against the current room's area, snapshotting all room coordinates
-- after each run, then diffs every run against run 1.
local function run_layout_determinism_test(label, mutateFn, numRuns)
    numRuns = numRuns or 5

    local roomID = getRoomIDbyHash(map.room_info.vnum)
    if type(roomID) ~= "number" or roomID < 1 then
        echo("Cannot test: current room is unknown.\n")
        return
    end

    local snapshots = {}
    echo("Running " .. label .. " " .. numRuns .. " times to test determinism...\n")

    for runNum = 1, numRuns do
        mutateFn()
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
                echo("  Run " .. runNum .. ": captured " .. table.size(snapshot) .. " rooms.\n")
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

function map.test_normalize_determinism(numRuns)
    run_layout_determinism_test("map normalize", map.normalize_room_layout, numRuns)
end

function map.test_recalculate_determinism(numRuns)
    run_layout_determinism_test("map recalculate", map.recalculate_room_layout, numRuns)
end

-- --------------------------------------------------------------------------
-- Area argument
-- --------------------------------------------------------------------------

-- Resolve the area a command should work on: an explicit id, an area name
-- (case-insensitive), or — with no argument — the one the player is standing in.
-- Returns nil plus the message to show when none of those produce an area.
local function resolve_area_arg(areaNameArg)
    if type(areaNameArg) == "number" and areaNameArg > 0 then
        return areaNameArg
    end
    if type(areaNameArg) == "string" and areaNameArg ~= "" then
        local areas = getAreaTable()
        if type(areas) == "table" then
            for name, id in pairs(areas) do
                if string.lower(name) == string.lower(areaNameArg) then
                    return id
                end
            end
        end
        return nil, "Cannot find area: " .. areaNameArg .. "\n"
    end
    local _room, currentAreaID = _.get_current_area_context()
    if not currentAreaID then
        return nil, "Cannot determine current area. Move to a room first or specify an area name.\n"
    end
    return currentAreaID
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

    local areaID, areaErr = resolve_area_arg(areaNameArg)
    if not areaID then
        echo(areaErr)
        return
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
        if shouldDelete and _.delete_room(rid) then
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
-- Room provenance
-- --------------------------------------------------------------------------

-- Room and area names are printed inside cecho strings, where a '<' would be
-- eaten as the start of a colour tag.
local function safe_echo_text(text)
    if type(text) ~= "string" or text == "" then return "(unnamed)" end
    return (text:gsub("[<>]", ""))
end

local function origin_when(stamp)
    local at = tonumber(stamp)
    if not at then return tostring(stamp or "?") end
    return os.date("%Y-%m-%d %H:%M", at)
end

-- Why does this room exist, and was the player ever in it?  A room that was
-- created for a neighbour's exit and never entered is indistinguishable from a
-- walked one once it has a name and exits, so the map is stamped as it happens
-- (see _.stamp_room_origin in Helpers.lua) and this reads it back.
--
-- Rooms that predate the stamping have nothing recorded, which is reported as
-- such rather than guessed at.
function map.show_room_origin(roomIDArg)
    local roomID = tonumber(roomIDArg)
    if not roomID then
        roomID = _.get_selected_map_room and _.get_selected_map_room() or nil
    end
    if not roomID then
        roomID = _.current_player_room_id and _.current_player_room_id() or nil
    end
    if type(roomID) ~= "number" or roomID < 1 then
        echo("map origin: give a room id, select a room on the mapper, or stand in one.\n")
        return
    end
    if type(getRoomArea) == "function" then
        local area = getRoomArea(roomID)
        if type(area) ~= "number" or area < 1 then
            echo("map origin: room " .. roomID .. " does not exist.\n")
            return
        end
    end

    local name = type(getRoomName) == "function" and getRoomName(roomID) or nil
    local hash = type(getRoomHashByID) == "function" and getRoomHashByID(roomID) or nil
    local x, y, z = getRoomCoordinates(roomID)
    local prov = _.read_room_provenance(roomID)

    cecho(string.format("\n<white>=== room %d<reset> <grey>%s<reset>\n",
        roomID, safe_echo_text(name)))
    if x ~= nil then
        cecho(string.format("<grey>  at (%d,%d,%d) in %s<reset>\n", x, y, z,
            safe_echo_text(_.get_area_name_by_id(getRoomArea(roomID)) or "?")))
    end
    if type(hash) == "string" and hash ~= "" then
        cecho("<grey>  hash " .. hash .. "<reset>\n")
        -- A room still named after its own hash was never given a real name,
        -- which is the plain-sight version of "never visited".
        if name == hash then
            cecho("<yellow>  name is the hash: never populated from a room description<reset>\n")
        end
    end

    if prov.origin then
        cecho(string.format("<cyan>  created<reset> %s%s <grey>%s<reset>\n",
            prov.origin,
            prov.detail and (" (" .. prov.detail .. ")") or "",
            origin_when(prov.created)))
    else
        cecho("<yellow>  created: not recorded — the room predates origin stamping<reset>\n")
    end

    if prov.visited then
        cecho("<green>  visited<reset> <grey>" .. origin_when(prov.visited) .. "<reset>\n")
    elseif prov.origin then
        cecho("<yellow>  never entered by the player<reset>\n")
    else
        cecho("<yellow>  visited: not recorded — walk into it once to confirm either way<reset>\n")
    end

    if #prov.history > 0 then
        cecho("<cyan>  history<reset>\n")
        for _i, entry in ipairs(prov.history) do
            cecho(string.format("<grey>    %s %s%s<reset>\n",
                origin_when(entry.at), entry.event,
                entry.detail and (" (" .. entry.detail .. ")") or ""))
        end
    end
    cecho("\n")
    return prov
end

-- --------------------------------------------------------------------------
-- Layout audit
-- --------------------------------------------------------------------------

local function audit_room_name(roomID)
    return safe_echo_text(type(getRoomName) == "function" and getRoomName(roomID) or nil)
end

-- Room ids are printed often enough here that they are worth making clickable:
-- every one of these findings is something you have to go and look at.  The
-- link is optional — an older client without cechoLink still gets the id.
local function audit_room_id(roomID)
    local label = "<cyan>#" .. tostring(roomID) .. "<reset>"
    if type(cechoLink) == "function" and type(centerview) == "function" then
        cechoLink(label, "centerview(" .. tostring(roomID) .. ")",
            "Center the map on room " .. tostring(roomID), true)
    else
        cecho(label)
    end
end

local function audit_room_list(roomIDs, maxShown)
    for i = 1, math.min(maxShown or #roomIDs, #roomIDs) do
        if i > 1 then cecho("<grey>, <reset>") end
        audit_room_id(roomIDs[i])
    end
    local hidden = #roomIDs - math.min(maxShown or #roomIDs, #roomIDs)
    if hidden > 0 then
        cecho(string.format("<grey> +%d more<reset>", hidden))
    end
end

-- Read-only report of what is still wrong with an area's layout, naming the
-- rooms involved.  The line normalize and recalculate print at the end says how
-- many anomalies are left; this says which ones, because the category no layout
-- pass can repair on its own — exits pointing at the wrong room — is only
-- actionable once you know where to walk.  Nothing here writes to the map.
--
-- limitArg caps how many entries each category lists; the totals in the headers
-- are always the real ones.
-- Close the seam at the current room by hand, for a chunk that was already
-- joined to the map before seam closing existed — the automatic pass only fires
-- on the arrival or the exit wiring that discovers a seam, and one already sat
-- through is never rediscovered.
function map.close_seam()
    local roomID = _.current_player_room_id()
    if not roomID or roomID < 1 then
        echo("Cannot close a seam: current room is unknown.\n")
        return
    end
    local areaID   = getRoomArea(roomID)
    local posCache = type(_.live_pos_cache) == "function" and _.live_pos_cache(areaID) or nil
    local moved    = _.close_component_seam(roomID, posCache, true) or 0
    if moved > 0 then
        updateMap()
        echo("Seam closed: " .. moved .. " room" .. (moved == 1 and "" or "s")
            .. " moved as one piece.\n")
    else
        if type(map._seam_reason) == "string" then
            echo("Nothing moved: " .. map._seam_reason .. ".\n")
        else
            echo("Nothing moved: this room's exits all land where they should, "
                .. "so it is not on a seam.\n")
        end
    end
end

-- Sweep a whole area for seams rather than just the one under your feet.
function map.close_area_seams(areaNameArg)
    local areaID, areaErr = resolve_area_arg(areaNameArg)
    if not areaID then
        echo(areaErr)
        return
    end
    local areaName = _.get_area_name_by_id(areaID) or ("area #" .. tostring(areaID))
    local result   = _.close_area_seams(areaID)
    updateMap()
    if result.closed == 0 then
        if type(map._seam_reason) == "string" then
            echo("No seams closed in '" .. areaName .. "'. Last one examined: "
                .. map._seam_reason .. ".\n")
        else
            echo("No seams closed in '" .. areaName .. "': nothing is displaced.\n")
        end
        return
    end
    echo(string.format(
        "Closed %d seam%s in '%s': %d room%s moved, over %d pass%s.\n",
        result.closed, result.closed == 1 and "" or "s", areaName,
        result.rooms_moved, result.rooms_moved == 1 and "" or "s",
        result.passes, result.passes == 1 and "" or "es"))
end

function map.audit_layout(areaNameArg, limitArg)
    local areaID, areaErr = resolve_area_arg(areaNameArg)
    if not areaID then
        echo(areaErr)
        return
    end

    local rooms = getAreaRooms(areaID)
    if type(rooms) ~= "table" or #rooms == 0 then
        echo("Nothing to audit: that area has no rooms.\n")
        return
    end

    local limit = tonumber(limitArg) or tonumber(map.configs.audit_max_listed) or 15
    if limit < 1 then limit = 1 end

    local counts     = _.audit_layout_anomalies(rooms, areaID, true)
    local details    = counts.details or {}
    local areaName   = _.get_area_name_by_id(areaID) or ("area #" .. tostring(areaID))

    cecho(string.format("\n<white>=== map audit: %s <grey>(%d room%s)<reset>\n",
        safe_echo_text(areaName), #rooms, #rooms == 1 and "" or "s"))

    local reported = 0
    local function section(total, title, note)
        if (total or 0) <= 0 then return false end
        reported = reported + total
        cecho(string.format("\n<cyan>%s<reset> <grey>(%d)<reset>\n", title, total))
        if note then cecho("<grey>  " .. note .. "<reset>\n") end
        return true
    end
    local function overflow(total)
        if total > limit then
            cecho(string.format("<grey>  ... and %d more<reset>\n", total - limit))
        end
    end

    -- Exit data that is wrong in the map, not merely laid out badly.  No amount
    -- of normalize or recalculate fixes these; the exits themselves have to go.
    local shared = details.shared_target or {}
    if section(#shared, "Shared-target exits",
        "one direction from several rooms lands on the same room — "
        .. "the duplicate exits are wrong, not the coordinates") then
        for i = 1, math.min(limit, #shared) do
            local entry = shared[i]
            cecho("  <white>" .. safe_echo_text(tostring(entry.dir)) .. "<reset> from ")
            audit_room_list(entry.sources, limit)
            cecho(" <grey>-><reset> ")
            audit_room_id(entry.target)
            cecho(" <grey>" .. audit_room_name(entry.target) .. "<reset>\n")
        end
        overflow(#shared)
    end

    local dupes = details.duplicate_hash or {}
    if section(#dupes, "Duplicate-hash rooms",
        "several rooms claim the same game room — 'map normalize' merges them") then
        for i = 1, math.min(limit, #dupes) do
            cecho("  ")
            audit_room_list(dupes[i].rooms, limit)
            cecho(" <grey>" .. audit_room_name(dupes[i].rooms[1]) .. "<reset>\n")
        end
        overflow(#dupes)
    end

    local loops = details.self_loops or {}
    if section(#loops, "Self-loop exits",
        "an exit pointing back at its own room — stripped by normalize/recalculate") then
        for i = 1, math.min(limit, #loops) do
            cecho("  ")
            audit_room_id(loops[i].room)
            cecho(" <white>" .. safe_echo_text(tostring(loops[i].dir))
                .. "<reset> <grey>-> itself<reset>\n")
        end
        overflow(#loops)
    end

    -- Geometry.  These are what the layout passes exist to fix, so what is left
    -- here is what they could not.
    local overlaps = details.overlapping or {}
    if section(#overlaps, "Rooms sharing a cell",
        "no free neighbouring cell, or every occupant is locked") then
        for i = 1, math.min(limit, #overlaps) do
            local cell = overlaps[i]
            cecho(string.format("  <grey>(%d,%d,%d)<reset> ", cell.x, cell.y, cell.z))
            audit_room_list(cell.rooms, limit)
            cecho("\n")
        end
        overflow(#overlaps)
    end

    local mismatches = details.delta_mismatches or {}
    if section(#mismatches, "Delta mismatches",
        "the exit's direction disagrees with where the two rooms sit; a loop that "
        .. "does not close cannot have every exit satisfied at once") then
        for i = 1, math.min(limit, #mismatches) do
            local entry = mismatches[i]
            cecho("  ")
            audit_room_id(entry.room)
            cecho(" <white>" .. safe_echo_text(tostring(entry.dir)) .. "<reset> <grey>-><reset> ")
            audit_room_id(entry.target)
            cecho(string.format("<grey>  is (%d,%d,%d), should be (%d,%d,%d)<reset>\n",
                entry.dx, entry.dy, entry.dz, entry.ex, entry.ey, entry.ez))
        end
        overflow(#mismatches)
    end

    local drift = details.vertical_drift or {}
    if section(#drift, "Vertical drift",
        "up/down pairs stacked on the right column but the wrong number of levels apart") then
        for i = 1, math.min(limit, #drift) do
            local entry = drift[i]
            cecho("  ")
            audit_room_id(entry.room)
            cecho(" <white>" .. safe_echo_text(tostring(entry.dir)) .. "<reset> <grey>-><reset> ")
            audit_room_id(entry.target)
            cecho(string.format("<grey>  dz %d, should be %d<reset>\n", entry.dz, entry.ez))
        end
        overflow(#drift)
    end

    local stranded = details.unreachable or {}
    if section(#stranded, "Unreachable rooms",
        "no exits of their own and nothing in the area exits to them") then
        for i = 1, math.min(limit, #stranded) do
            cecho("  ")
            audit_room_id(stranded[i])
            cecho(" <grey>" .. audit_room_name(stranded[i]) .. "<reset>\n")
        end
        overflow(#stranded)
    end

    if reported == 0 then
        cecho("<green>No anomalies found.<reset>\n")
    end
    if (counts.cross_area or 0) > 0 then
        cecho(string.format(
            "<grey>%d exit%s out of the area (normal at borders, not counted above).<reset>\n",
            counts.cross_area, counts.cross_area == 1 and "" or "s"))
    end
    cecho("<grey>Read-only: nothing was moved.<reset>\n\n")
    return counts
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
    echo("    5) Snaps in-area up/down room pairs to exact ±1 z-offsets, without moving their (x,y).\n")
    echo("    6) Moves rooms onto the elevation they belong on: surface terrain to z=0 and sky rooms\n")
    echo("       to z=1..3 by counting how far they are above the ground. Rooms move in rigid groups,\n")
    echo("       so a room with no elevation of its own travels with the neighbours that have one.\n")
    echo("    7) Separates distinct rooms that ended up on the same cell.\n")
    echo("    8) Reports remaining anomalies by category (cyclic mismatches, shared-target bugs, etc.).\n")
    echo("    Steps 5-8 are shared with 'map recalculate'; only how the coordinates are produced differs.\n")
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
    echo("  map follow [on|off]\n")
    echo("    Show or set whether each room you walk into is positioned one step from the room\n")
    echo("    you just left, in the direction you walked. On by default.\n")
    echo("    This is what makes a manual fix stick: move a room with 'map shift' (or run\n")
    echo("    'map normalize'), then walk on, and the rooms you enter follow from it instead of\n")
    echo("    snapping back to where they were. A room you locked with 'map lock' is never moved,\n")
    echo("    and neither is one whose exits give no direction (a portal or a special exit).\n")
    echo("    A room already sitting on the target cell is pushed to the nearest free cell when\n")
    echo("    the arriving room's own exits agree with that cell better than the occupant's do.\n")
    echo("    Geography that cannot fit a grid (e.g. three rooms that loop by going east three\n")
    echo("    times) walks one cell further out each lap; 'map lock' one room of the loop to\n")
    echo("    pin it, or turn this off.\n\n")
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
    echo("       Each room is placed at parent-coords + exit-direction (z included); first BFS\n")
    echo("       path wins. Rooms that land on an occupied position are nudged to the nearest\n")
    echo("       free spot. z is purely exit-derived; there is no name-based auto z-split.\n")
    echo("    4) Removes stale BFS placeholder stubs left by the rebuild.\n")
    echo("    5) Then runs the same finishing stages as 'map normalize': vertical snap, alignment\n")
    echo("       elevation, overlap separation, and the anomaly report. The\n")
    echo("       elevation stage is what keeps the rebuild from inheriting whatever z the room\n")
    echo("       you started from happened to be on, since every other z is walked out from it.\n")
    echo("    Only the room you start it from is pinned; other locked rooms may still be moved.\n")
    echo("    More thorough than 'map normalize' — will displace any room that's in the way.\n")
    echo("    When to use: when large groups of rooms have fundamentally wrong coordinates,\n")
    echo("    e.g. two independently mapped groups linked by exits, or vertical stubs at z:0.\n")
    echo("    Use 'map normalize' first for safer, incremental repair.\n\n")
    echo("  map set poi\n")
    echo("    Set the current room's symbol to '#' and apply the Inside background color.\n")
    echo("    Useful for marking points of interest (shops, quest givers, etc.) on the map.\n\n")
    echo("  map origin [room id]\n")
    echo("    Say why a room exists and whether the player has ever been in it: created on\n")
    echo("    arrival, created because a neighbour reported an exit that way, adopted, or\n")
    echo("    promoted from a duplicate during a merge — with the history since.\n")
    echo("    Defaults to the selected mapper room, else the room you are standing in.\n")
    echo("    Rooms already in the map before this build have nothing recorded and say so.\n\n")
    echo("  map audit [area name] [N]\n")
    echo("    Read-only report of what is still wrong with the current (or named) area, naming\n")
    echo("    the rooms: shared-target exits, duplicate-hash rooms, self-loops, rooms sharing a\n")
    echo("    cell, delta mismatches, vertical drift and unreachable rooms.\n")
    echo("    Same checks step 9 of normalize/recalculate counts, listed instead of tallied.\n")
    echo("    Room ids are clickable and center the mapper on the room.\n")
    echo("    N caps how many entries each category lists (default "
        .. map.configs.audit_max_listed .. "); the totals shown are always the real ones.\n")
    echo("    Nothing is moved, so it is safe to run at any time.\n\n")
    echo("  map seam\n")
    echo("    Move the cluster the current room belongs to onto the position its links to the\n")
    echo("    rest of the map imply, as one rigid piece — for a chunk mapped in isolation and\n")
    echo("    later joined by a path. The smaller side of the seam moves; on a tie, the side\n")
    echo("    you are not standing in. Every crossing link must agree on the same offset, so\n")
    echo("    one uncontradicted link is enough and two that disagree stop it.\n")
    echo("    This runs by itself on the arrival or exit that discovers a seam; the command is\n")
    echo("    for seams already sitting in the map. Up to "
        .. tostring(map.configs.seam_max_component) .. " rooms (seam_max_component).\n\n")
    echo("  map seams [area name]\n")
    echo("    The same repair swept over a whole area, repeated until a pass moves nothing.\n")
    echo("    For seams that formed before seam closing existed, or that nothing has revisited\n")
    echo("    since: the automatic pass only fires on the arrival or exit that discovers one.\n")
    echo("    Closing one seam can supply the evidence another was missing, hence the passes.\n\n")
    echo("  map clean-placeholders [area name]\n")
    echo("    Delete placeholder rooms whose map position overlaps a real room in the current (or named) area.\n")
    echo("    Useful for cleaning up stale pre-visit stubs after using 'map recalculate' or 'map link-room'.\n\n")
    echo("  map remove poi\n")
    echo("    Remove the POI marker from the current room and restore its original terrain color.\n\n")
    echo("  map profile [on|off|reset|report [N]|status]\n")
    echo("    Measure where mapper time goes. 'on' instruments the hot path and counts every\n")
    echo("    Mudlet map API call; walk around (especially into unmapped rooms), then 'report'.\n")
    echo("    Ranks scopes by self time and lists the slowest individual room events with the\n")
    echo("    API calls each one made. 'off' restores everything and keeps the collected data.\n\n")
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
        -- No-op unless `map profile on`.  Any error here unwinds at the
        -- continue_walk wrapper, which pops back to its own entry depth.
        _.prof_enter("reevaluate_autowalk")
        maybe_reevaluate_autowalk()
        _.prof_exit()
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
-- We scan only a padded bounding box instead of iterating the entire area, to
-- avoid freezing on large maps.
local PLACEHOLDER_PAD = 5 -- extra tiles of padding around the path bounding box

local function first_room_in(hit)
    if type(hit) == "number" then
        if hit > 0 then return hit end
        return nil
    end
    if type(hit) ~= "table" then return nil end
    for _i, rid in ipairs(hit) do
        if type(rid) == "number" and rid > 0 then return rid end
    end
    return nil
end

-- Cell occupancy for one add_placeholder_exits scan: returns probe(x, y, z),
-- or nil when the map cannot be enumerated at all.
--
-- Every cell in the box used to be its own getRoomsByPosition call, and each of
-- those scans the area inside Mudlet.  At the 4,000-cell volume cap, plus ten
-- neighbour probes per placeholder found, one slow-path autowalk could issue
-- ~44,000 of them, and maybe_reevaluate_autowalk re-runs the slow path after
-- every step that creates a room.  A single walk of the area's rooms answers
-- every probe instead: free when the long-lived position cache already
-- describes this area, one O(area) coordinate walk otherwise.
--
-- The index is built one cell wider than the box on each axis because the scan
-- probes each placeholder's neighbours, which for a placeholder on the boundary
-- lie just outside it.
local function build_cell_probe(areaID, minX, maxX, minY, maxY, minZ, maxZ)
    local key = _.pos_cache_key

    local live = _.live_pos_cache(areaID)
    if _.pos_cache_is_authoritative(live, areaID) then
        return function(x, y, z) return first_room_in(live[key(x, y, z)]) end
    end

    local rooms = type(getAreaRooms) == "function" and getAreaRooms(areaID) or nil
    if type(rooms) == "table" then
        local occ = {}
        for _i, id in ipairs(rooms) do
            local x, y, z = getRoomCoordinates(id)
            if x ~= nil and y ~= nil and z ~= nil
                and x >= minX - 1 and x <= maxX + 1
                and y >= minY - 1 and y <= maxY + 1
                and z >= minZ - 1 and z <= maxZ + 1 then
                local k = key(x, y, z)
                if occ[k] == nil then occ[k] = id end
            end
        end
        return function(x, y, z) return occ[key(x, y, z)] end
    end

    if type(getRoomsByPosition) == "function" then
        return function(x, y, z) return first_room_in(getRoomsByPosition(areaID, x, y, z)) end
    end
    return nil
end

local function add_placeholder_exits(areaID, currentRoomID, targetRoomID)
    local unvisitedID = _.terrain_types["unvisited"] and _.terrain_types["unvisited"].id or 46
    local added       = {}
    if type(setExit) ~= "function" then return added end

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

    local room_at = build_cell_probe(areaID, minX, maxX, minY, maxY, minZ, maxZ)
    if room_at == nil then return added end

    -- Each room's exits are read once and then kept current as we add to them,
    -- so the "does this exit already exist" test still sees exits added earlier
    -- in this same scan (including the reverse exit a neighbouring placeholder
    -- just put on this room) without re-reading them from the client.  The read
    -- sat inside the direction loop before: up to twenty getRoomExits calls per
    -- placeholder, all but one of them redundant.
    local exitsOf = {}
    local function exits_of(roomID)
        local ex = exitsOf[roomID]
        if ex == nil then
            ex = getRoomExits(roomID)
            if type(ex) ~= "table" then ex = {} end
            exitsOf[roomID] = ex
        end
        return ex
    end

    local function link(fromID, toID, dir)
        local ex = exits_of(fromID)
        if ex[dir] ~= nil then return end
        setExit(fromID, toID, dir)
        ex[dir] = toID
        added[#added + 1] = { fromID, dir }
    end

    for z = minZ, maxZ do
        for y = minY, maxY do
            for x = minX, maxX do
                local rid = room_at(x, y, z)
                if rid and getRoomEnv(rid) == unvisitedID then
                    for dir, shift in pairs(_.move_vectors) do
                        local neighbourID = room_at(x + shift[1], y + shift[2], z + shift[3])
                        if neighbourID then
                            link(rid, neighbourID, dir)
                            local revDir = _.reverse_move_vectors[dir]
                            if revDir then link(neighbourID, rid, revDir) end
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
    -- Everything below is the slow path.  Scoped separately from the fast path
    -- above because the fast path is what most walks take, and averaging the
    -- two together hides how expensive the slow one is.  All profiler calls
    -- here are no-ops unless `map profile on`; the scope is closed before each
    -- of the two remaining returns.
    _.prof_enter("autowalk_slowpath")

    local areaID = getRoomArea(currentRoomID)

    local addedExits = {}
    if type(areaID) == "number" and areaID > 0 then
        _.prof_enter("placeholder_exits")
        addedExits = add_placeholder_exits(areaID, currentRoomID, targetRoomID)
        _.prof_exit()
    end

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

        _.prof_exit()
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
    _.prof_exit()
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

-- Guarded like the menu handlers below: Mudlet re-evaluates this chunk on every
-- profile load and script edit, and anonymous handlers registered by an earlier
-- evaluation stay alive, so an unguarded call stacks another copy of the whole
-- pipeline per reload.  `map` survives the reload (`map = map or {}` in
-- Data.lua), so the flag does too, and the surviving handlers resolve the
-- "map.eventHandler" name at dispatch time — they pick up the reloaded
-- function, which is why skipping re-registration loses nothing.
if not map.room_event_handlers_registered then
    registerAnonymousEventHandler("gmcp.Room.Info", "map.eventHandler")
    registerAnonymousEventHandler("shiftRoom", "map.eventHandler")
    registerAnonymousEventHandler("sysConnectionEvent", "map.eventHandler")
    map.room_event_handlers_registered = true
end

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
