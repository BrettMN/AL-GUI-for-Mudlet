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
-- Multi-pass reconcile may displace a room that is *less* in agreement with its
-- own exits than the room wanting its cell, instead of giving up on the move.
-- Without it, a cell held by a room the BFS has no reason to move is held for
-- good: repeated passes only ever relocate rooms an exit points at, so a squatter
-- that nothing points at, or one whose own placement already looks locally fine,
-- strands every room that legitimately belongs on that cell.  Set false to
-- restore the old skip-on-occupied behaviour.
map.configs.reconcile_evict = map.configs.reconcile_evict ~= false
-- How far an evicted room may be parked from the cell it lost.  Small on
-- purpose: it gets re-placed from its neighbours on the next pass, and a long
-- throw is visible on the map until then.
map.configs.reconcile_evict_radius = map.configs.reconcile_evict_radius or 8
map.configs.area_display_names = map.configs.area_display_names or {}
map.configs.area_ids_by_gmcp = map.configs.area_ids_by_gmcp or {}
map.configs.auto_reconcile = false
map.configs.debug_mapper = map.configs.debug_mapper == true
map.configs.autowalk_reevaluate = map.configs.autowalk_reevaluate ~= false
-- Areas with at least this many rooms skip work that is redone repeatedly and
-- is therefore never amortised: the full pos_cache build (rebuilt on every area
-- change and after every reconnect, so sub-functions fall back to direct
-- getRoomsByPosition look-ups instead) and the map stretch pass (O(area)
-- setRoomCoordinates writes every time a room is created).  Lower the value to
-- cut over sooner; raise it to re-enable both for moderately large areas.
map.configs.large_area_threshold = map.configs.large_area_threshold or 5000

-- Map stretching: when a new room's cell is already taken, relocate every room
-- on one side of that cell by one step to open it up.
--
-- Off, because it is the wrong trade on a coordinate-dense map.  The arrival
-- room is pinned while the pass runs, so every room around it slides one cell
-- along one axis and each exit that was correct becomes off by one — a single
-- collision spends the whole area's layout to seat one room.  On a wilderness
-- grid, where a placeholder already occupies nearly every cell, collisions are
-- the normal case rather than the exception: 'map audit' on a 2332-room area
-- read 739 delta mismatches, dominated by neighbours two cells out instead of
-- one on a single axis, which is this pass's fingerprint.
--
-- With it off the colliding room is simply placed, and the passes built for
-- exactly that state settle it: lowest-ID-wins dedup in
-- create_neighbors_for_current_room, then resolve_room_overlaps and reconcile
-- under 'map normalize'.  Set true to restore the old behaviour.
map.configs.stretch_area = map.configs.stretch_area == true

-- Grid mode is latched on per area: once an area has been seen in grid mode it
-- stays there, rather than being re-decided from the room the player currently
-- occupies.  Terrain is a property of a room, not of an area, so a terrain-less
-- room inside a wilderness — a tree, a tower, any interior — used to switch the
-- whole area's rendering off and then back on a step later.  Set false to let
-- every arrival re-decide (and flap).
map.configs.grid_mode_latch = map.configs.grid_mode_latch ~= false

-- Mark the far side of an exit that leaves the area with a POI room, placed on
-- the cell the exit points at.  The exit itself still points at the real room in
-- the other area, so routing across a border is unaffected; the marker exists
-- because that room lives in another coordinate frame and cannot be drawn here,
-- which otherwise leaves a border exit pointing at nothing visible.
map.configs.border_poi = map.configs.border_poi ~= false

-- May a placeholder that is already bound to one game room be re-bound to a
-- different one because it happens to sit where an exit points?
--
-- No.  A vnum is the server's own statement of identity; a map cell is an
-- inference from a walk, and where the two disagree the inference is what is
-- wrong.  Allowing the rebind is how one Mudlet room came to be adopted twice
-- for two different vnums 25 minutes apart, welding two unrelated stretches of
-- wilderness into one road that no layout pass could ever satisfy.  With it off
-- the exit is left as a stub and becomes a real room when the player walks it,
-- placed from the room they walked out of.
map.configs.rebind_placeholder_hash = map.configs.rebind_placeholder_hash == true

-- Deferred neighbour wiring.
--
-- On a large area a single arrival costs over a second, nearly all of it inside
-- create_neighbors_for_current_room: ~100ms per setExit, ~390ms for each
-- placeholder room's setRoomArea, ~19ms per occupancy probe.  Mudlet runs all of
-- that on the main thread, so the client cannot repaint or accept input for the
-- duration, and during auto travel arrivals outrun it and the backlog turns a
-- stutter into a multi-minute lock-up.
--
-- Rather than doing every exit of an arriving room before returning, the exits
-- are queued and wired one per timer tick, so the longest uninterruptible span
-- drops from a whole room to a single exit.  Set false to wire inline as before.
map.configs.defer_neighbor_wiring = map.configs.defer_neighbor_wiring ~= false
-- Exits wired per drain tick.  One keeps the main thread free between units;
-- the drain scales this up on its own once the backlog passes the soft cap.
map.configs.deferred_neighbor_per_tick = map.configs.deferred_neighbor_per_tick or 1
-- Backlog past which the drain stops yielding to arrivals and starts catching
-- up in bigger batches.  Nothing is ever dropped: a dropped exit is a hole in
-- the forward graph that map normalize and map recalculate both navigate by.
map.configs.deferred_neighbor_soft_cap = map.configs.deferred_neighbor_soft_cap or 2000

-- On a large area, mark an exit leading somewhere unvisited with Mudlet's own
-- exit stub rather than creating a placeholder room to stand in for it.  A
-- placeholder costs ~500ms there (setRoomArea alone ~396ms) and most are never
-- walked; a stub carries the same "an exit leaves here" information for no
-- measurable cost.  The exit to the real room is written when the player walks
-- it, so the forward graph that map normalize and map recalculate navigate by
-- stays complete for every connection actually travelled.
--
-- The trade-off: autowalk cannot route through unexplored space in those areas,
-- because add_placeholder_exits needs real placeholder rooms to chain together.
-- Set false to go back to creating placeholders everywhere.
map.configs.stub_unexplored_exits = map.configs.stub_unexplored_exits ~= false

-- Move a room onto the cluster its exits say it adjoins, as soon as enough of
-- those exits are known (see _.realign_displaced_room in Layout.lua).  Rooms
-- created without a directional clue land on a probed free cell, and only the
-- later discovery of their exits reveals where they actually belong.  This is
-- the cheap local form of what 'map normalize' does globally: the check is
-- reads only, and nothing is written unless a move is warranted.
map.configs.realign_displaced_rooms = map.configs.realign_displaced_rooms ~= false
-- Agreeing exits required before a room is moved.  One exit is not evidence:
-- a single mis-wired exit would be enough to throw a correctly placed room
-- across the map.  Two independent exits pointing at the same cell is.
map.configs.realign_min_votes = map.configs.realign_min_votes or 2
-- Largest group that may be translated in one go.  Rooms displaced together
-- move together, and a group that grows past this has reached the main body of
-- the map through some other seam — repositioning that is 'map normalize's
-- job, and doing it mid-step would stall the client.
map.configs.realign_max_component = map.configs.realign_max_component or 32

-- Close a seam as soon as one is discovered: when a cluster that is internally
-- consistent turns out to be joined to the rest of the map at an offset, move
-- the whole cluster onto the position that link implies, rigidly.
--
-- This is the companion to realign_displaced_rooms, for the case that one
-- cannot serve.  Realign asks a single room whether its own exits agree on
-- somewhere better and wants two of them to say so; the moment a path into an
-- isolated chunk is established there is exactly one such exit, outvoted by
-- every exit that room already had.  Asking the cluster instead makes a single
-- uncontradicted link sufficient — see _.close_component_seam.
map.configs.close_seams = map.configs.close_seams ~= false
-- Largest cluster that may be translated this way.  Both sides of the seam are
-- measured and the smaller one moves, so this is really "how isolated does a
-- chunk have to be".  Well above realign_max_component because the test is
-- unanimity across every link rather than a majority of one room's exits.
map.configs.seam_max_component = map.configs.seam_max_component or 500

-- Absolute elevation anchoring.
--
-- Every other z in this mapper is relative: a room's z is the previous room's z
-- plus whatever the walked direction contributed.  Nothing says where the
-- ground *is*, so a cluster seeded without a directional clue picks up an
-- arbitrary z origin, grows internally consistent, and only reveals the error
-- when it meets a cluster with a different origin — as a wall of exits whose
-- delta is right in x and y and off by a constant in z.  Rooms first reached by
-- descending from such a cluster inherit its error, which is how sky ends up
-- intermingled with land on one plane.
--
-- An anchor is the fix: surface terrain means z 0, and a sky room means as many
-- levels above 0 as it takes `down` moves to reach the surface.  Both are
-- absolute and neither reads a neighbour's coordinates, so a room converges on
-- the right plane no matter what its cluster believes.
map.configs.anchor_elevation = map.configs.anchor_elevation ~= false
-- Highest sky level recognised.  A `down` chain longer than this is not
-- believed: it means the chain has left the sky stack (or the exits are wrong),
-- and guessing a level from bad data is worse than leaving the room alone.
map.configs.sky_max_level = map.configs.sky_max_level or 3
-- How many sky rooms to search sideways for an altitude when the room's own
-- `down` chain does not reach the surface.  Horizontal moves do not change
-- altitude, so a sky room's neighbours are at its level — this is what anchors
-- the interior of a sky layer, where only the edges have `down` exits.
map.configs.sky_altitude_search = map.configs.sky_altitude_search or 16
-- When a whole group cannot be lifted onto its plane in one piece, the rooms in
-- it may instead be offered to the single-room anchor — but only up to this many.
-- That fallback exists for one narrow case: a stacked sky column whose top room
-- is standing on the cell the one below it needs, which the single-room path
-- resolves by climbing the column.  Applied to a group of any real size it does
-- the opposite of a repair, moving the rooms that happen to know their own
-- height and stranding every room that does not, one at a time, until the frame
-- is shredded.  A blocked group bigger than this is left exactly as it is.
map.configs.elevation_max_single_group = map.configs.elevation_max_single_group or 32
-- Hard ceiling on `map recalculate`.  Its BFS is single-pass and rebuilds every
-- coordinate from the seed outward, so a run that stops early does not leave the
-- area half-repaired — it leaves it half-rebuilt, with the rebuilt part in one
-- frame and the rest in another, which is far worse than not having run at all.
-- Above this the command refuses rather than truncating.
map.configs.recalculate_max_rooms = map.configs.recalculate_max_rooms or 200000

-- How many entries `map audit` lists per anomaly category.  The header always
-- carries the real total; this only bounds the wall of text, since a broken area
-- can hold hundreds of one kind and the first handful is what gets walked to.
map.configs.audit_max_listed = map.configs.audit_max_listed or 15

-- Areas with at least this many rooms get no per-area hash/name index (see the
-- "Per-area room index" section in Helpers.lua).  That index is built once and
-- then reused across steps *and* across area changes, so it tolerates a far
-- bigger area than the per-entry pos_cache does — this cap exists only to bound
-- the one-off build and the memory the index holds, not a per-step cost.
map.configs.index_area_threshold = map.configs.index_area_threshold or 50000

-- Private cross-file table; helpers and functions are stored here so they are
-- accessible across Lua chunks without polluting the global namespace.
map._ = map._ or {}
local _ = map._

-- Profiler scope markers.  Defined here as no-ops because Profile.lua loads
-- last, while the call sites that use them live in Core.lua and Commands.lua —
-- those call sites run at event time, but they are written unconditionally, so
-- the names have to exist from the first chunk onwards.  `map profile on` swaps
-- in the recording implementations; `map profile off` puts these back.
local function prof_noop() end

_.prof_enter = prof_noop
_.prof_exit  = prof_noop

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

-- Room names that mean "this room is in the air above the surface".
-- Matched case-insensitively as a substring, like _.is_elevated_room_name.
--
-- Deliberately NOT added to elevated_name_patterns: that list drives a *relative*
-- +1/-1 nudge in make_room, applied on top of the shift the walked direction
-- already contributed.  Going up from the ground into the sky supplies +1 from
-- the `up` exit, so a second bump would land the room two levels above where it
-- belongs.  Sky rooms get an absolute plane instead (see _.sky_altitude).
_.sky_name_patterns = {
    "the sky",
}
