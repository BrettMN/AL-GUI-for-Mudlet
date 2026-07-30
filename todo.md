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

- [x] **PERF-1 — Two-to-three full-area scans on every newly-discovered room**
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
      **Done.** One per-area index in `Helpers.lua` serves both scans:
      `map._area_index[areaID] = { byHash = {[hash]=id}, byName = {[lowerName]={id,...}} }`,
      built by `_.build_area_index`, capped at 8 resident areas, dropped on
      `sysConnectionEvent`. `resolve_room_id_by_hash` and `find_real_room_to_adopt` Phase 2
      are both now O(matches) instead of O(area); Phase 2 no longer walks `getAreaRooms`
      at all (`_.rooms_with_name`).
      Staleness is asymmetric: bindings we make are folded in via `_.bind_room_hash` /
      `_.set_room_name` (Core 5 sites, Layout 5), so the index never *misses* an entry;
      clears, renames, deletes and area moves are caught on read by re-verifying each
      candidate against `getRoomHashByID`/`getRoomName`/`getRoomArea` and pruning, so the
      13 `setRoomIDbyHash(id, "")` sites in the dedup code stayed untouched.
      Sized by the new `index_area_threshold` (50000), not `large_area_threshold` — the
      index survives area changes, so it amortises where the pos cache does not.

- [x] **PERF-2 — `build_reverse_exit_index` walks the entire world, once per merge**
      `Helpers.lua:1601-1634`, `Helpers.lua:1268`, `Helpers.lua:1651-1656`
      It calls `getRooms()` (all rooms, all areas) with `getRoomExits` + `getSpecialExitsSwap`
      per room. `map.dedupe_area_by_hash` correctly builds it once (`Helpers.lua:1809`), but
      `snap_vertical_pair` → `resolve_overlap` passes `nil`, so `merge_duplicate_room` rebuilds
      the whole-world index for *each* overlap merged. 50 overlaps = 50 full-world scans in
      one `map normalize`.
      **Done.** `snap_vertical_pair` now owns one index for the whole call and threads it
      into every `merge_duplicate_room`, so 50 overlaps cost 1 full-world walk instead of 50.
      It is built **lazily** on the first merge that actually needs it: most calls resolve no
      overlaps at all and previously paid nothing, so an eager build at the top would have
      made the common path worse.
      Sharing one index across chained merges needed `merge_duplicate_room` to stop treating
      it as read-only, because `resolve_overlap` feeds each survivor back in as the next
      target and that survivor can become the next loser. It now records every edge it
      creates (inbound rewrites in step 1, inherited outbound exits in steps 2-3) and drops
      the loser's list after deletion, so a later merge sees a complete inbound list rather
      than silently leaving sources pointing at a deleted room.
      Also added a live-source check before rewriting an inbound exit: an entry can name a
      room a previous merge deleted, and writing an exit onto one of Mudlet's leftover ghost
      IDs can resurrect it (the same failure `Layout.lua` guards against for positions).
      `build_reverse_exit_index` moved from a file-local to `_.build_reverse_exit_index`
      because `snap_vertical_pair` is defined above it.

- [x] **PERF-3 — Position cache rebuilt per reconcile pass and per subgraph seed**
      `Layout.lua:642`, `Layout.lua:968-975`, `Layout.lua:1059-1065`
      `local posCache = sharedCache or _.build_pos_cache(areaID)` sits *inside* the
      `for _pass = 1, maxPasses` loop, and `normalize_room_layout` never passes
      `externalPosCache` — with `reconcile_deep_max_passes = 20` that is 20 O(N) rebuilds.
      `map normalize all` / `normalize_all_areas` then call it once per unvisited seed;
      placeholder rooms create many small disconnected subgraphs, so seeds can number in the
      hundreds → hundreds × 20 × O(N) for one command.
      **Done.** The build is hoisted above the pass loop in `_.reconcile_connected_rooms`, so
      a call is one build regardless of `maxPasses`, and both seed loops
      (`normalize_room_layout`, `normalize_all_areas`) now thread `externalPosCache` — which
      until now had no caller at all. Hundreds × 20 × O(N) becomes O(N) per area.
      The cache threaded through is the one already built for the dedup step, not a fresh
      one: `merge_duplicate_room` drops each loser from it and never moves a survivor, so it
      is current by the time reconcile runs (see **PERF-4**, which extends the same cache to
      the rest of the pipeline).
      `_.flatten_cardinal_connected_rooms` had to take the cache too. It runs *between* seeds
      and calls `setRoomCoordinates` with no cache bookkeeping; that was invisible while every
      seed rebuilt, but with a shared cache it would leave later seeds reading pre-flatten
      z-values. It mirrors the move only when both coords are non-nil, since `pos_cache_key`
      builds keys by concatenation and would raise on a nil z.

- [x] **PERF-4 — One `map normalize` builds the pos cache 4+ times**
      `Layout.lua:956`, `Layout.lua:993`, `Layout.lua:1010` (passes `nil`, so
      `resolve_room_overlaps` builds its own), `Helpers.lua:1196` (inside `snap_vertical_pair`).
      **Done.** `normalize_room_layout` and `normalize_all_areas` now build one cache per area
      and thread it through all of steps 2-6 — dedup, reconcile, flatten, snap, anchor
      translate, overlap resolve. One `map normalize` is one O(area) coordinate walk instead
      of four-plus; `map normalize all` is one per area instead of four per area.
      Only `_.snap_vertical_pair` needed a new parameter; `dedupe_area_by_hash`,
      `apply_anchor_translation` and `resolve_room_overlaps` already accepted one and were
      simply being handed `nil` or a redundant fresh build. `map recalculate` still lets
      `snap_vertical_pair` build its own, because recalculate tracks occupancy in its own BFS
      `occupied` table and has no posCache to share.
      In `normalize_room_layout` the cache is declared outside `run_normalize_pipeline` and
      assigned inside it, because step 6 runs after the closure returns and
      `with_single_locked_anchor`'s `xpcall` only carries four return values.
      **One correctness change was required.** `merge_duplicate_room` dropped the loser from
      the cache *before* calling `_.delete_room`, which is a `pcall` that can report failure.
      While every pass rebuilt, a room dropped from the cache but not actually deleted
      reappeared on the next build; with one shared cache it would stay invisible to every
      later pass. The delete now happens first (coords read before it, since they are
      unreadable afterwards) and the cache edit is conditional on the delete being accepted.

- [x] **PERF-5 — Position cache is bypassed for every empty cell**
      `Layout.lua:133`, `Layout.lua:221`, `Layout.lua:323`, `Helpers.lua:941`, `Helpers.lua:978`
      `pos_cache_get` returns `nil` both for "large-area sentinel, no data" *and* for "cell is
      genuinely empty". While exploring, most probed cells are empty, so the
      `getRoomsByPosition` fallback fires constantly and the C++ call is paid anyway — on top
      of having built the cache.
      **Done.** `_.rooms_at_position(cache, areaID, x, y, z)` replaces the
      `pos_cache_get(...) or getRoomsByPosition(...)` idiom at all five sites (plus the two
      raw probes in `make_room`). It falls back only when the cache genuinely holds no data —
      `_large_area` sentinel, wrong area, or no cache — so an empty cell in a real cache is
      answered from the cache. Measured on a stubbed map: one first visit to a 4-exit room
      cost 8 `getRoomsByPosition` calls before and 0 after, each of which is an O(area) scan
      inside Mudlet.
      **Trusting a miss meant closing every hole that could leave a cache stale-empty**, since
      "cell is free" is now believed without checking. Coordinate writes go through a new
      `_.set_room_coordinates` wrapper (all 15 `setRoomCoordinates` sites) that mirrors the
      move into both the caller's cache and the long-lived `map._pos_cache`, and
      `_.set_room_area` / `_.delete_room` now maintain `map._pos_cache` too. That last part
      matters most: `map._pos_cache` lives for as long as the player stays in one area, but
      `make_room`'s area-wide stretch, `map normalize`, `map recalculate` and
      `map fix-selected-layout` all move rooms through caches of their own and used to leave
      it describing a map that no longer existed. `_.pos_cache_move` lost its last caller and
      was removed. What remains uncoverable is a room moved in Mudlet's own map editor.
      Sentinels are still *written* to (`pos_cache_matches_area`, not
      `pos_cache_is_authoritative`, gates mirroring), because the per-event dedup backstop in
      `create_neighbors_for_current_room` reads the sentinel's partial data directly.
      **Two things had to change to survive `_.delete_room` touching the cache.** The final
      dedup backstop (`Layout.lua:514`) iterates the cache's own occupant array while deleting
      from it and removed the entry with `table.remove(list, i)`; now that `_.delete_room`
      drops the room by value first, an index-based remove would take out whichever live room
      shifted into slot `i`. It removes by value instead. And `stretch_area_for_new_room`
      tested `ox ~= nil` only *after* doing arithmetic on the coordinates, so a room in
      `posCache._rooms` that had been deleted (or was never placed) faulted on the nil — the
      guard moved ahead of the arithmetic, in both that function and the copy of the loop in
      `make_room`.

- [x] **PERF-6 — `find_free_cell_near` is O(R³)**
      `Helpers.lua:1075`
      Scans the full (2r+1)² square each ring to test only the perimeter. With the default
      `maxRadius = 64` that is ~350k iterations per call instead of ~16k. Called once per
      overlapping room in `resolve_room_overlaps` and per blocked vertical snap.
      **Done.** The ring walk is now three explicit segments — west column in full, each
      intermediate column's two ends, east column in full — so the interior is never visited.
      An exhausted search at `maxRadius = 64` costs 12,544 loop iterations instead of 366,144
      for the same 16,640 cell look-ups; measured 1.6x faster wall-clock in that worst case,
      where the surviving `pos_cache_get` calls (and their key concatenation) dominate.
      Probe *order* is deliberately unchanged from the square scan (the old `dx` outer / `dy`
      inner filter visits the perimeter in exactly that segment order), so the cell returned
      for any given cache is identical and no caller's placement decisions shift. Verified by
      diffing both implementations' probe sequences and return values over 400 randomized
      occupancy blobs plus the fully-blocked case.

- [x] **PERF-7 — `audit_layout_anomalies` calls `getRoomExits` three times per room**
      `Helpers.lua:1396`, `Helpers.lua:1428`, `Helpers.lua:1449`
      Separate passes for the target tally, the incoming-exit set, and the main audit.
      Collapsible into one pass; runs at the end of every normalize/recalculate.
      **Done.** One `getRoomExits` pass now builds `targetCount`, `hasIncoming` and the
      duplicate-hash tally at once, keeping each room's exit table in `exitsOf` for the
      classification loop to re-walk. Two passes remain because the classification of *any*
      room needs those tables complete — a room's `unreachable` verdict depends on exits
      declared by a room later in the list — but the second pass no longer touches the client.
      `getRoomArea` and `getRoomCoordinates` are memoised for the same reason: both were read
      once per exit for targets already read as sources.
      Measured on a stubbed 1,370-room area (3.0 exits/room average): `getRoomExits` 4,110 →
      1,370 calls, `getRoomArea` 4,534 → 768, `getRoomCoordinates` 2,998 → 1,423. Wall clock
      is only 1.21x better *in the stub*, where those calls are plain Lua returns; in Mudlet
      each is a C++ call and `getRoomExits` allocates a fresh table per call, so the real
      saving tracks the call counts more closely than the stub's clock. Peak Lua heap did not
      grow despite holding all exit tables at once (measured 694 KB vs 915 KB) — the old
      version allocated the same tables three times over and left two thirds as garbage.
      Verified by diffing all eight bucket counts against the previous implementation over 500
      randomized maps (mixed named/numeric/special exit keys, string-typed targets, self
      loops, dangling and zero targets, unplaced rooms, foreign-area rooms, shared hashes,
      partial scope lists, duplicate list entries) plus hand-built edge cases: 0 mismatches.

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

- [x] **PERF-10 — `large_area_threshold = 50000` is far above its stated intent**
      `Data.lua:23`
      The comment cites freezes "for minutes", but a 49,999-room area still takes the full
      path — 50k `getRoomCoordinates` calls on every area change and after every reconnect.
      3k–5k matches the intent much better.
      **Done, but the single knob had to be split first.** At 50000 it gated four things
      with opposite cost profiles. `large_area_threshold` is now 5000 and covers only the
      work that is re-paid and never amortised — the pos cache (rebuilt on every area change
      and reconnect) and the hot-path map stretch. The per-area hash/name index from
      **PERF-1** moved to its own `index_area_threshold` (50000) because it is built once and
      survives area changes; leaving it on the 5000 knob would have silently disabled hash
      repair and Phase 2 adoption on every area over 5k rooms, undoing PERF-1.
      The `map normalize` size warning keeps the 5000 knob (per-command work, not amortised)
      and its text was retuned, since "hundreds of thousands of rooms" no longer describes
      the trigger.
      *Depended on **BUG-3**, now fixed:* the room-count estimate that both thresholds read
      only ever drifted upward, and crossing 5000 is 10x more likely than crossing 50000.

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

- [x] **BUG-1 — `table.is_empty` used without the fallback `Core.lua` bothered to write**
      `Helpers.lua:943`, `Helpers.lua:980` call it directly in the movement hot path, while
      `Core.lua:11` defines `is_empty_t` on the grounds that `table.is_empty` may be
      unavailable. One of the two is wrong.
      **Done as a side effect of PERF-5.** Both calls tested the result of the
      `pos_cache_get(...) or getRoomsByPosition(...)` idiom; `_.rooms_at_position` now returns
      `nil` for an empty cell instead of an empty table, so the call sites are plain `== nil`
      checks. The two `is_empty_t` uses in `make_room` went the same way, so neither helper
      has any caller left in `map/` and `is_empty_t` was deleted. (Running the pre-change
      `Helpers.lua` outside Mudlet does fail on `attempt to call field 'is_empty'`, so the
      `Core.lua` side was the correct one.)

- [ ] **BUG-2 — Undefined speedwalk config keys**
      `Commands.lua:933`, `Commands.lua:1047-1049` read `map.configs.speedwalk_random`,
      `use_translation`, and `lang_dirs`, none of which are defined in `Data.lua`. Setting
      `use_translation = true` indexes nil and errors mid-walk.

- [x] **BUG-3 — Area room-count cache drifts upward permanently**
      `_.adjust_area_room_count` is only ever called with `+1` (`Core.lua:173`,
      `Layout.lua:265`) despite many `deleteRoom` sites, and `_.invalidate_area_room_count`
      (`Helpers.lua:603`) is never called at all. `is_large_area` can latch true after heavy
      dedup churn, silently disabling the pos cache and hash repair.
      **Done.** Three lifecycle wrappers in `Helpers.lua` now own the count, and the raw
      Mudlet calls appear nowhere else in `map/`:
      `_.add_room` (2 sites), `_.set_room_area` (6 sites, debits the old area and credits the
      new one so area *moves* balance), `_.delete_room` (all 6 `deleteRoom` sites, reads the
      area before the room goes away and returns whether Mudlet accepted the delete so
      callers keep their tallies and `pos_cache_drop`s in step).
      The two standalone `+1` calls are gone; creation is counted by `_.add_room` or
      `_.set_room_area`, whichever first sees the room in a valid area, and
      `_.set_room_area`'s `oldArea == areaID` early-out stops it double-counting when Mudlet
      drops new rooms into a default area.
      `_.invalidate_area_room_count` gained its first real caller in
      `maybe_delete_empty_area`, alongside `_.invalidate_area_index`, so a recycled area ID
      cannot inherit a dead area's count or index. External edits are covered by the
      `sysConnectionEvent` reset and by `_.record_area_room_count`, which corrects the
      estimate for free from the `getAreaRooms` walks `build_area_index` and
      `build_pos_cache` already do.

- [ ] **BUG-4 — `map normalize area <name>` is non-deterministic**
      `Layout.lua:889-894` takes the first substring match from `pairs(getAreaTable())`;
      iteration order is not stable, so the same command can target a different area run to
      run.

- [ ] **BUG-5 — `find_nearest_unoccupied` returns an occupied cell on failure**
      `Helpers.lua:1122` returns the original `x, y, z` when the radius-20 search fails, so
      `recalculate` stacks the room rather than reporting it.

- [ ] **BUG-6 — Dead code**
      `verticalDirs` (`Core.lua:25`) is declared and never used; `local newRooms`
      (`Core.lua:543`) is assigned and never read. *(The `_large_area` sentinel is no longer
      dead — PERF-5 made it the thing that decides whether a cache miss is trustworthy.)*
      Also the file-local `build_pos_cache` in `Layout.lua` (~line 552): a second, differently
      shaped cache builder (key → single roomID, no `_areaID`/`_rooms`) with no callers — every
      call site uses `_.build_pos_cache` from `Helpers.lua`. Its `pos_key` helper *is* still
      used by `map.recalculate_room_layout`, so only the builder goes.
