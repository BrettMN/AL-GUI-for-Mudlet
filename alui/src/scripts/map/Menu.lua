-- Mapping Script — Menu
-- Builds the Mudlet mapper right-click context menu and handles menu events.
--
-- Adds a "Set Terrain" submenu listing canonical terrain names.
-- Clicking an entry raises the "alui.map.set_terrain" event with the terrain
-- name; the handler applies the environment and stored terrain metadata to
-- every currently-selected room.

map                     = map or {}
map._                   = map._ or {}
local _                 = map._

local LEGACY_MENU_ROOT  = "alui_map_root"
local MENU_TERRAIN      = "alui_map_set_terrain"
local EVENT_SET_TERRAIN = "alui.map.set_terrain"

local function copy_room_ids(roomIDs)
    if type(roomIDs) ~= "table" then return {} end
    local copied = {}
    for _, roomID in ipairs(roomIDs) do
        if type(roomID) == "number" and roomID > 0 then
            copied[#copied + 1] = roomID
        end
    end
    return copied
end

local function get_rooms_for_terrain_menu()
    if type(_.get_selected_map_rooms) == "function" then
        local roomIDs = _.get_selected_map_rooms()
        if type(roomIDs) == "table" and #roomIDs > 0 then
            return roomIDs
        end
    end

    if type(getMapSelection) == "function" then
        local selection = getMapSelection()
        if type(selection) == "table" then
            local roomIDs = copy_room_ids(selection.rooms)
            if #roomIDs > 0 then
                return roomIDs
            end
            if type(selection.center) == "number" and selection.center > 0 then
                return { selection.center }
            end
        end
    end

    if type(getSelectedRooms) == "function" then
        local roomIDs = copy_room_ids(getSelectedRooms())
        if #roomIDs > 0 then
            return roomIDs
        end
    end

    local cached = copy_room_ids(map.last_selected_rooms)
    if #cached > 0 then
        return cached
    end

    if type(map.last_selected_room) == "number" and map.last_selected_room > 0 then
        return { map.last_selected_room }
    end

    return {}
end

local function resolve_terrain_name(...)
    local args = { ... }
    for _i, candidate in ipairs(args) do
        if type(candidate) == "string" and candidate ~= "" then
            local canonical = _.normalize_terrain_name(candidate)
            if canonical and _.terrain_types and _.terrain_types[canonical] then
                return canonical
            end

            local fromUnique = candidate:match("^alui_map_terrain_(.+)$")
            if fromUnique then
                fromUnique = fromUnique:gsub("_", " ")
                canonical = _.normalize_terrain_name(fromUnique)
                if canonical and _.terrain_types and _.terrain_types[canonical] then
                    return canonical
                end
            end
        end
    end
    return nil
end

local function terrain_menu_label(terrainName)
    if terrainName == "lake" then
        return "fresh water"
    end
    return terrainName
end

-- ---------------------------------------------------------------------------
-- Build the menu.  Safe to call multiple times: clears any previous entries
-- first so the terrain list stays in sync if _.terrain_types changes.
-- ---------------------------------------------------------------------------
function _.setup_map_menu()
    if type(addMapMenu) ~= "function" or type(addMapEvent) ~= "function" then
        return -- mapper API unavailable (very old Mudlet)
    end

    -- Remove old entries (no-op if they don't exist).
    if type(removeMapMenu) == "function" then
        pcall(removeMapMenu, MENU_TERRAIN)
        pcall(removeMapMenu, LEGACY_MENU_ROOT)
    end

    -- Put "Set Terrain" at the top level of the mapper right-click menu.
    addMapMenu(MENU_TERRAIN, nil, "Set Terrain")

    local names = {}
    if type(_.terrain_menu_names) == "table" and #_.terrain_menu_names > 0 then
        for _i, name in ipairs(_.terrain_menu_names) do
            names[#names + 1] = name
        end
    else
        -- Fallback if Data.lua has not built the canonical menu list yet.
        for name, spec in pairs(_.terrain_types or {}) do
            if type(spec) == "table" and type(spec.id) == "number" then
                names[#names + 1] = name
            end
        end
        table.sort(names)
    end

    for _i, name in ipairs(names) do
        local uniqueId = "alui_map_terrain_" .. name:gsub("%W", "_")
        addMapEvent(uniqueId, EVENT_SET_TERRAIN, MENU_TERRAIN, terrain_menu_label(name), name)
    end
end

-- ---------------------------------------------------------------------------
-- Event handler: applies the picked terrain to every selected room.
-- Mudlet's event arguments for addMapEvent are inconsistent across releases:
-- some versions pass just the custom arguments, others also include the menu
-- item's unique name. Accept either shape.
-- ---------------------------------------------------------------------------
function _.on_set_terrain(_event, arg1, arg2, ...)
    local terrainName = resolve_terrain_name(arg1, arg2, ...)
    if type(terrainName) ~= "string" or terrainName == "" then
        echo("Unknown terrain selection.\n")
        return
    end

    local spec = _.terrain_types and _.terrain_types[terrainName]
    if type(spec) ~= "table" or type(spec.id) ~= "number" then
        echo("Unknown terrain: " .. tostring(terrainName) .. "\n")
        return
    end

    local rooms = get_rooms_for_terrain_menu()
    if type(rooms) ~= "table" or #rooms == 0 then
        echo("No rooms selected.  Right-click on a room (or select several) and try again.\n")
        return
    end

    local storedTerrain = _.normalize_terrain_name(terrainName) or terrainName
    local changed = 0
    for _i, rid in ipairs(rooms) do
        local ok = pcall(function()
            _.apply_room_environment(rid, terrainName)
            setRoomUserData(rid, "terrain", storedTerrain)
        end)
        if ok then changed = changed + 1 end
    end

    if type(updateMap) == "function" then updateMap() end

    echo(string.format("Set terrain '%s' on %d room%s.\n",
        terrainName, changed, changed == 1 and "" or "s"))
end

-- ---------------------------------------------------------------------------
-- Wire up: register the event handler, then build the menu.
-- Re-registering replaces the existing handler, so this is safe on reload.
-- ---------------------------------------------------------------------------
if type(registerNamedEventHandler) == "function" then
    registerNamedEventHandler(getProfileName(), "alui.map.setTerrain",
        EVENT_SET_TERRAIN, function(...) _.on_set_terrain(...) end, false)
end

_.setup_map_menu()
