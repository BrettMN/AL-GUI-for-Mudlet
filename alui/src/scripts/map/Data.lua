-- Mapping Script — Data
-- Shared data tables used across multiple map/ files.
-- Stored in map._ so they survive the Mudlet per-chunk local scope boundary.

map = map or {}
map.room_info = map.room_info or {}
map.prev_info = map.prev_info or {}
map.configs = map.configs or {}
map.configs.speedwalk_delay = 0
map.configs.reconcile_max_passes = map.configs.reconcile_max_passes or 1
map.configs.reconcile_max_moves = map.configs.reconcile_max_moves or 200
map.configs.reconcile_deep_max_passes = map.configs.reconcile_deep_max_passes or 20
map.configs.reconcile_deep_max_moves = map.configs.reconcile_deep_max_moves or 5000
map.configs.area_display_names = map.configs.area_display_names or {}
map.configs.area_ids_by_gmcp = map.configs.area_ids_by_gmcp or {}
map.configs.auto_reconcile = false
map.configs.debug_mapper = map.configs.debug_mapper == true
map.configs.autowalk_reevaluate = map.configs.autowalk_reevaluate ~= false

-- Private cross-file table; helpers and functions are stored here so they are
-- accessible across Lua chunks without polluting the global namespace.
map._ = map._ or {}
local _ = map._

_.terrain_types = {
    -- used to make rooms of different terrain types have different colors
    -- add a new entry for each terrain type, and set the color with RGB values
    -- each id value must be unique, terrain types not listed here will use mapper default color
    -- not used if you define these in a map XML file
    ["Inside"] = { id = 1, r = 255, g = 0, b = 0 },
    ["plains"] = { id = 19, r = 0, g = 255, b = 0 },
    ["light forest"] = { id = 17, r = 34, g = 139, b = 34 }, -- 'forestgreen'
    ["dense forest"] = { id = 18, r = 0, g = 100, b = 0 },   -- 'darkgreen'
    ["hills"] = { id = 21, r = 218, g = 165, b = 32 },       -- 'goldenrod'
    ["mountains"] = { id = 22, r = 160, g = 82, b = 45 },    -- 'sienna'
    ["lake"] = { id = 23, r = 0, g = 25, b = 167 },
    ["under the lake"] = { id = 23, r = 0, g = 25, b = 167 },
    ["swamp"] = { id = 24, r = 128, g = 0, b = 128 },    -- 'purple'
    ["desert"] = { id = 25, r = 240, g = 230, b = 140 }, -- 'khaki'
    ["min river"] = { id = 26, r = 0, g = 25, b = 167 },
    ["river"] = { id = 27, r = 0, g = 25, b = 167 },
    ["sw river"] = { id = 28, r = 0, g = 25, b = 167 },
    ["w river"] = { id = 29, r = 0, g = 25, b = 167 },
    ["nw river"] = { id = 30, r = 0, g = 25, b = 167 },
    ["n river"] = { id = 31, r = 0, g = 25, b = 167 },
    ["ne river"] = { id = 32, r = 0, g = 25, b = 167 },
    ["e river"] = { id = 33, r = 0, g = 25, b = 167 },
    ["se river"] = { id = 34, r = 0, g = 25, b = 167 },
    ["s river"] = { id = 35, r = 0, g = 25, b = 167 },
    ["max river"] = { id = 36, r = 0, g = 25, b = 167 },
    ["ocean"] = { id = 37, r = 0, g = 0, b = 128 },           -- 'navy'
    ["under ocean"] = { id = 37, r = 0, g = 0, b = 128 },     -- 'navy'
    ["under the ocean"] = { id = 37, r = 0, g = 0, b = 128 }, -- 'navy'
    ["under lake"] = { id = 38, r = 0, g = 25, b = 167 },
    ["under river"] = { id = 39, r = 0, g = 25, b = 167 },
    ["sky"] = { id = 40, r = 135, g = 206, b = 235 },    -- 'skyblue'
    ["road"] = { id = 41, r = 211, g = 211, b = 211 },   -- 'lightgrey'
    ["bridge"] = { id = 42, r = 211, g = 211, b = 211 }, -- 'lightgrey'
    ["beach"] = { id = 43, r = 255, g = 239, b = 213 },  -- 'papayawhip'
    ["pond"] = { id = 44, r = 0, g = 25, b = 167 },
    ["tundra"] = { id = 45, r = 245, g = 245, b = 245 }, -- 'whitesmoke'
    ["unvisited"] = { id = 46, r = 50, g = 50, b = 50 }, -- light grey placeholder
}

-- Canonical user-facing terrain names. Variants that should behave like the
-- same terrain (for menus, stored room data, and reverse lookups) map to a
-- single preferred name here.
_.terrain_canonical_names = {
    ["inside"] = "Inside",
    ["lake"] = "lake",
    ["under the lake"] = "lake",
    ["under lake"] = "lake",
    ["river"] = "lake",
    ["min river"] = "lake",
    ["sw river"] = "lake",
    ["w river"] = "lake",
    ["nw river"] = "lake",
    ["n river"] = "lake",
    ["ne river"] = "lake",
    ["e river"] = "lake",
    ["se river"] = "lake",
    ["s river"] = "lake",
    ["max river"] = "lake",
    ["under river"] = "lake",
    ["pond"] = "lake",
    ["ocean"] = "ocean",
    ["under ocean"] = "ocean",
    ["under the ocean"] = "ocean",
}

do
    for name, spec in pairs(_.terrain_types) do
        if type(spec) == "table" then
            local lower = string.lower(name)
            if _.terrain_canonical_names[lower] == nil then
                _.terrain_canonical_names[lower] = name
            end
        end
    end
end

_.terrain_menu_names = {}
do
    local seen = {}
    for name, spec in pairs(_.terrain_types) do
        if type(spec) == "table" then
            local canonical = _.terrain_canonical_names[string.lower(name)] or name
            if _.terrain_types[canonical] and not seen[canonical] then
                seen[canonical] = true
                _.terrain_menu_names[#_.terrain_menu_names + 1] = canonical
            end
        end
    end
    table.sort(_.terrain_menu_names)
end

-- Reverse lookup: envID → canonical terrain name.
-- Built once here so Helpers.lua never has to scan terrain_types in a loop.
_.envID_to_terrain = {}
do
    local skip = { Inside = true, unvisited = true }
    for name, spec in pairs(_.terrain_types) do
        if type(spec) == "table" then
            local canonical = _.terrain_canonical_names[string.lower(name)] or name
            if not skip[canonical] then
                _.envID_to_terrain[spec.id] = canonical
            end
        end
    end
end

-- list of possible movement directions and appropriate coordinate changes
_.move_vectors = {
    north = { 0, 1, 0 },
    northeast = { 1, 1, 0 },
    east = { 1, 0, 0 },
    southeast = { 1, -1, 0 },
    south = { 0, -1, 0 },
    southwest = { -1, -1, 0 },
    west = { -1, 0, 0 },
    northwest = { -1, 1, 0 },
    up = { 0, 0, 1 },
    down = { 0, 0, -1 }
}

_.exitmap = {
    n = 'north',
    ne = 'northeast',
    e = 'east',
    se = 'southeast',
    s = 'south',
    sw = 'southwest',
    w = 'west',
    nw = 'northwest',
    u = 'up',
    d = 'down',
    ["in"] = 'in',
    out = 'out',
    l = 'look'
}

-- Precompute reverse mapping (full → short) for O(1) lookups
_.short = {}
for k, v in pairs(_.exitmap) do
    _.short[v] = k
end

-- Precompute reverse move vectors
_.reverse_move_vectors = {}
for dir, vec in pairs(_.move_vectors) do
    for rdir, rvec in pairs(_.move_vectors) do
        if vec[1] == -rvec[1] and vec[2] == -rvec[2] and vec[3] == -rvec[3] then
            _.reverse_move_vectors[dir] = rdir
            break
        end
    end
end

-- Terrain names whose "canonical" z-level is 0 (outdoor surface terrain).
-- IMPORTANT – normalisation-pass hint only.
-- This table is consulted by map.normalize_room_layout and
-- map.recalculate_room_layout to migrate a *whole connected component* onto
-- the surface z-plane.  It must NOT be used to override the z of a single
-- freshly-created neighbour room during ordinary movement: doing so snaps
-- rooms to z=0 even when the surrounding cluster lives at a different z,
-- which produces the delta_mismatch anomaly described in the mapper audit.
-- See _.get_forced_z_for_room for the query helper.
_.forced_z_by_terrain_name = {
    ["plains"] = 0,
    ["light forest"] = 0,
    ["dense forest"] = 0,
    ["hills"] = 0,
    ["mountains"] = 0,
    ["lake"] = 0,
    ["swamp"] = 0,
    ["river"] = 0,
    ["ocean"] = 0,
    ["road"] = 0,
    ["bridge"] = 0,
    ["beach"] = 0,
    ["pond"] = 0,
    ["tundra"] = 0,
}
