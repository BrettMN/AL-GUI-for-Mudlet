-- Mapping Script — Menu
-- Builds the Mudlet mapper right-click context menu and handles menu events.
--
-- Adds a "Set Terrain" submenu listing every terrain in _.terrain_types.
-- Clicking an entry raises the "alui.map.set_terrain" event with the terrain
-- name; the handler applies setRoomEnv to every currently-selected room.

map                     = map or {}
map._                   = map._ or {}
local _                 = map._

local MENU_ROOT         = "alui_map_root"
local MENU_TERRAIN      = "alui_map_set_terrain"
local EVENT_SET_TERRAIN = "alui.map.set_terrain"

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
        pcall(removeMapMenu, MENU_ROOT)
    end

    -- Top-level "ALUI" submenu, then "Set Terrain" submenu under it.
    addMapMenu(MENU_ROOT, nil, "ALUI")
    addMapMenu(MENU_TERRAIN, MENU_ROOT, "Set Terrain")

    -- Collect & sort terrain names for a stable menu order.
    local names = {}
    for name, spec in pairs(_.terrain_types or {}) do
        if type(spec) == "table" and type(spec.id) == "number" then
            names[#names + 1] = name
        end
    end
    table.sort(names)

    for _i, name in ipairs(names) do
        local uniqueId = "alui_map_terrain_" .. name:gsub("%W", "_")
        addMapEvent(uniqueId, EVENT_SET_TERRAIN, MENU_TERRAIN, name, name)
    end
end

-- ---------------------------------------------------------------------------
-- Event handler: applies the picked terrain to every selected room.
-- Mudlet raises the map-menu event with the menu item's uniqueName as the
-- first arg, followed by any extra args supplied to addMapEvent.  We passed
-- the terrain name as the extra arg, so it arrives in the second slot.
-- ---------------------------------------------------------------------------
function _.on_set_terrain(_event, _uniqueName, terrainName)
    if type(terrainName) ~= "string" or terrainName == "" then return end

    local spec = _.terrain_types and _.terrain_types[terrainName]
    if type(spec) ~= "table" or type(spec.id) ~= "number" then
        echo("Unknown terrain: " .. tostring(terrainName) .. "\n")
        return
    end

    local rooms = (type(getSelectedRooms) == "function") and getSelectedRooms() or {}
    if type(rooms) ~= "table" or #rooms == 0 then
        echo("No rooms selected.  Right-click on a room (or select several) and try again.\n")
        return
    end

    local changed = 0
    for _i, rid in ipairs(rooms) do
        local ok = pcall(setRoomEnv, rid, spec.id)
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
