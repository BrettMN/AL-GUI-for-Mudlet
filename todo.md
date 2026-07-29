# TODO — `alui/src/scripts/map` review

Findings from a performance/security review of the mapper Lua (`Data.lua`, `Core.lua`,
`Helpers.lua`, `Layout.lua`, `Commands.lua`, `Menu.lua`) and the `map` aliases.

No RCE-class issues exist — there is no `loadstring`, `os.execute`, file, or network I/O
anywhere in `map/`. Items below are ordered within each section by impact.

Suggested first pass: SEC-1, PERF-1, PERF-2, PERF-3, PERF-11.

---

## Security

- [ ] **SEC-1 — Server-controlled text interpolated into `cecho` markup**
      `Core.lua:191`, `Core.lua:300`, `Layout.lua:931`
      `info.vnum` / `info.name` / `areaName_display` come from `gmcp.Room.Info` or the map
      file and are concatenated into a `cecho("<yellow>" .. msg .. "<reset>")`. `cecho`
      parses `<...>` as colour tags, so a vnum containing `<red>` recolours the console and
      an unknown tag raises a Lua error inside the GMCP queue drain. The `pcall` at
      `Core.lua:564` stops it crashing the profile but silently abandons the room update, so
      a server can selectively break mapping.
      *Fix:* use `echo()` for the interpolated portion, or escape `<` before concatenating.

- [ ] **SEC-2 — GMCP input is never validated or bounded**
      `Core.lua:608-630`, `Core.lua:55-57`, `Layout.lua:260-274`
      `map.eventHandler` copies `gmcp.Room.Info.exits` wholesale with no cap on key count and
      no type check on `vnum`/`area`. Each unrecognised exit vnum creates a room; each unseen
      area string calls `addAreaName()`. A hostile or buggy server can inflate the map file
      without limit from a single event.
      *Fix:* reject non-string `vnum`/`area` at the queue boundary and cap exits per event
      (~32).

- [ ] **SEC-3 — Server-driven `deleteRoom` on real rooms**
      `Layout.lua:338-421`, `Layout.lua:447-539`
      The dedup passes delete every non-`locked` room sharing a cell with the exit target,
      keeping only the lowest ID. A real, hash-bearing, unlocked room can be deleted during
      ordinary movement based on server-supplied exit data. Not undoable, no confirmation.
      Downstream consequence of SEC-2 — fix that first, then tighten the delete criteria.

- [ ] **SEC-4 — Temporary map mutations are not exception-safe**
      `Commands.lua:1300-1342`
      `add_placeholder_exits` writes real `setExit` calls and `compute_autowalk_path` calls
      `lockRoom(id, true)` on every POI in the area. Both are reverted only on the normal
      return path — if `getPath` errors, the injected exits and room locks persist
      permanently in the user's map.
      *Fix:* `pcall` with the cleanup in a finally-style block.

- [ ] **SEC-5 — `send()` transmits map-derived strings verbatim** *(minor)*
      `Commands.lua:945`, `Commands.lua:1062`
      `speedWalkDir` entries for special exits are command strings stored in the map file, so
      an imported third-party map can send arbitrary commands to the game.

- [ ] **SEC-6 — Clipboard export includes all room user data** *(minor)*
      `Commands.lua:719`, `Commands.lua:749`
      `map.export_rooms` puts `getAllRoomUserData` for every selected room on the system
      clipboard. Harmless today; means any future room user-data is clipboard-visible by
      default.

---

## Performance

- [ ] **PERF-1 — Two-to-three full-area scans on every newly-discovered room**
      `Helpers.lua:230-238`, `Helpers.lua:376-393`
      Biggest item, because it fires on the hot path — walking into an unmapped room.
      `handle_move` sees `rnum < 1` → `_.resolve_room_id_by_hash` walks the hint area calling
      `getRoomHashByID` per room, then repeats for the previous room's area. On the (normal)
      miss, `_.find_real_room_to_adopt` Phase 2 does a *third* full walk with
      `getRoomHashByID` + `getRoomName` per room, plus `score_exit_match` (another
      `getRoomExits`) per name match. ~6,000 C++ round-trips per step in a 2,000-room area,
      scaling linearly with area size. `find_real_room_to_adopt` has no `is_large_area` guard.
      *Fix:* maintain a hash→ID index per area (invalidated on `setRoomIDbyHash`) instead of
      re-scanning; gate Phase 2 behind the same large-area check.

- [ ] **PERF-2 — `build_reverse_exit_index` walks the entire world, once per merge**
      `Helpers.lua:1601-1634`, `Helpers.lua:1268`, `Helpers.lua:1651-1656`
      It calls `getRooms()` (all rooms, all areas) with `getRoomExits` + `getSpecialExitsSwap`
      per room. `map.dedupe_area_by_hash` correctly builds it once (`Helpers.lua:1809`), but
      `snap_vertical_pair` → `resolve_overlap` passes `nil`, so `merge_duplicate_room` rebuilds
      the whole-world index for *each* overlap merged. 50 overlaps = 50 full-world scans in
      one `map normalize`.

- [ ] **PERF-3 — Position cache rebuilt per reconcile pass and per subgraph seed**
      `Layout.lua:642`, `Layout.lua:968-975`, `Layout.lua:1059-1065`
      `local posCache = sharedCache or _.build_pos_cache(areaID)` sits *inside* the
      `for _pass = 1, maxPasses` loop, and `normalize_room_layout` never passes
      `externalPosCache` — with `reconcile_deep_max_passes = 20` that is 20 O(N) rebuilds.
      `map normalize all` / `normalize_all_areas` then call it once per unvisited seed;
      placeholder rooms create many small disconnected subgraphs, so seeds can number in the
      hundreds → hundreds × 20 × O(N) for one command.
      *Fix:* hoist the build out of the pass loop and thread one cache through the seed loop.
      The cache is already mutated in place correctly.

- [ ] **PERF-4 — One `map normalize` builds the pos cache 4+ times**
      `Layout.lua:956`, `Layout.lua:993`, `Layout.lua:1010` (passes `nil`, so
      `resolve_room_overlaps` builds its own), `Helpers.lua:1196` (inside `snap_vertical_pair`).

- [ ] **PERF-5 — Position cache is bypassed for every empty cell**
      `Layout.lua:133`, `Layout.lua:221`, `Layout.lua:323`, `Helpers.lua:941`, `Helpers.lua:978`
      `pos_cache_get` returns `nil` both for "large-area sentinel, no data" *and* for "cell is
      genuinely empty". While exploring, most probed cells are empty, so the
      `getRoomsByPosition` fallback fires constantly and the C++ call is paid anyway — on top
      of having built the cache.
      *Fix:* key the fallback off `posCache._large_area` (already set at `Layout.lua:75` and
      `Core.lua:406`, currently never read) instead of `near == nil`.

- [ ] **PERF-6 — `find_free_cell_near` is O(R³)**
      `Helpers.lua:737-748`
      Scans the full (2r+1)² square each ring to test only the perimeter. With the default
      `maxRadius = 64` that is ~350k iterations per call instead of ~16k. Called once per
      overlapping room in `resolve_room_overlaps` and per blocked vertical snap.
      *Fix:* iterate the perimeter directly.

- [ ] **PERF-7 — `audit_layout_anomalies` calls `getRoomExits` three times per room**
      `Helpers.lua:1396`, `Helpers.lua:1428`, `Helpers.lua:1449`
      Separate passes for the target tally, the incoming-exit set, and the main audit.
      Collapsible into one pass; runs at the end of every normalize/recalculate.

- [ ] **PERF-8 — `add_placeholder_exits` can issue ~44,000 `getRoomsByPosition` calls**
      `Commands.lua:1226-1252`, `Commands.lua:1348`
      Volume cap is 4,000 cells; each cell costs a `room_at` call and each placeholder found
      costs 10 more plus `getRoomExits`. Runs in `compute_autowalk_path`'s slow path, which
      `maybe_reevaluate_autowalk` re-triggers whenever `map.autowalk_dirty` is set — i.e.
      after every step that creates a room.
      *Fix:* cache the placeholder-exit scaffold for the duration of one walk.

- [ ] **PERF-9 — GMCP queue is unbounded and drains in O(n²)**
      `Core.lua:563`, `Core.lua:626`
      `table.remove(room_event_queue, 1)` shifts the whole array per item, and coalescing only
      compares against the tail entry — alternating vnums defeat it entirely while the drain
      rate is capped at 3 per timer tick.
      *Fix:* use a head index (as `Helpers.lua:1867` already does) and cap queue length.

- [ ] **PERF-10 — `large_area_threshold = 50000` is far above its stated intent**
      `Data.lua:23`
      The comment cites freezes "for minutes", but a 49,999-room area still takes the full
      path — 50k `getRoomCoordinates` calls on every area change and after every reconnect.
      3k–5k matches the intent much better.

- [ ] **PERF-11 — Duplicate event handlers on script reload**
      `Commands.lua:1466-1468`
      The `gmcp.Room.Info` / `shiftRoom` / `sysConnectionEvent` registrations have no
      `map.*_registered` guard, unlike the three registrations ten lines below them. Mudlet
      re-evaluates script chunks on profile load and on every script edit, so each reload
      stacks another handler — after N reloads every `Room.Info` runs the whole pipeline N
      times. Looks like an oversight rather than a deliberate choice.

- [ ] **PERF-12 — 4 Hz selection polling timer**
      `Commands.lua:1171`
      `tempTimer(0.25, ..., true)` calls `getMapSelection()` four times a second forever,
      whether or not the mapper is open. It does correctly kill the prior timer on reload. If
      Mudlet's version exposes a selection-changed event, that is the better trigger.

---

## Smaller bugs

- [ ] **BUG-1 — `table.is_empty` used without the fallback `Core.lua` bothered to write**
      `Helpers.lua:943`, `Helpers.lua:980` call it directly in the movement hot path, while
      `Core.lua:11` defines `is_empty_t` on the grounds that `table.is_empty` may be
      unavailable. One of the two is wrong.

- [ ] **BUG-2 — Undefined speedwalk config keys**
      `Commands.lua:933`, `Commands.lua:1047-1049` read `map.configs.speedwalk_random`,
      `use_translation`, and `lang_dirs`, none of which are defined in `Data.lua`. Setting
      `use_translation = true` indexes nil and errors mid-walk.

- [ ] **BUG-3 — Area room-count cache drifts upward permanently**
      `_.adjust_area_room_count` is only ever called with `+1` (`Core.lua:173`,
      `Layout.lua:265`) despite many `deleteRoom` sites, and `_.invalidate_area_room_count`
      (`Helpers.lua:603`) is never called at all. `is_large_area` can latch true after heavy
      dedup churn, silently disabling the pos cache and hash repair.

- [ ] **BUG-4 — `map normalize area <name>` is non-deterministic**
      `Layout.lua:889-894` takes the first substring match from `pairs(getAreaTable())`;
      iteration order is not stable, so the same command can target a different area run to
      run.

- [ ] **BUG-5 — `find_nearest_unoccupied` returns an occupied cell on failure**
      `Helpers.lua:1122` returns the original `x, y, z` when the radius-20 search fails, so
      `recalculate` stacks the room rather than reporting it.

- [ ] **BUG-6 — Dead code**
      `verticalDirs` (`Core.lua:25`) is declared and never used; `local newRooms`
      (`Core.lua:543`) is assigned and never read; the `_large_area` sentinel field is written
      but never read (see PERF-5).
