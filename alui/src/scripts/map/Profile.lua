-- Mapping Script — Profile
-- Opt-in instrumentation for the mapper hot path.
--
-- Two independent measurements, both off until `map profile on`:
--
--   * Scope timing.  Named regions (`_.prof_enter` / `_.prof_exit`, plus the
--     function wrappers installed below) accumulate call count, total wall
--     time and self time.  Self time is total minus the time spent inside
--     nested scopes, so a caller that is slow only because its callee is slow
--     shows a large total and a small self.
--
--   * Mudlet API call counts.  The map API globals are replaced with counting
--     wrappers while profiling is on.  This is the measurement that matters
--     for freeze hunting: every one of these is a C++ round-trip, and the
--     functions under suspicion are slow because they issue O(area) of them
--     rather than because of anything Lua does.
--
-- Both are restored exactly on `map profile off` — the wrappers keep the
-- original function and put it back, so a reload mid-session cannot leave a
-- wrapper stacked on a wrapper (see install_api_wrappers).

map    = map or {}
map._  = map._ or {}
local _ = map._

-- --------------------------------------------------------------------------
-- Clock
-- --------------------------------------------------------------------------
-- getEpoch() is Mudlet's high-resolution wall clock.  os.clock() is Lua 5.1's
-- CPU clock and is the fallback: for a freeze that is CPU-bound in C++ calls
-- the two agree closely enough to rank call sites, which is all this is for.
local now
if type(getEpoch) == "function" then
    now = getEpoch
else
    now = os.clock
end

-- --------------------------------------------------------------------------
-- State
-- --------------------------------------------------------------------------

map.profile = map.profile or {}
local P     = map.profile

P.enabled   = P.enabled or false
P.scopes    = P.scopes or {}  -- name -> { calls, total, self, max }
P.api       = P.api or {}     -- name -> count
P.apiTime   = P.apiTime or {} -- name -> { total, max } seconds spent inside Mudlet
P.samples   = P.samples or {} -- worst top-level scope completions
P.started   = P.started or nil

-- Top-level completions slower than this (seconds) are kept with their full
-- API-call breakdown.  Anything faster is folded into the scope totals only.
map.configs.profile_sample_threshold = map.configs.profile_sample_threshold or 0.05
-- How many slow samples to retain.  The worst are kept, not the most recent:
-- the interesting event is the one that froze the client, and it is usually
-- followed by dozens of ordinary ones that would evict it from a ring buffer.
map.configs.profile_max_samples = map.configs.profile_max_samples or 25

local stack = {}

local function scope_stats(name)
    local s = P.scopes[name]
    if s == nil then
        s = { calls = 0, total = 0, self = 0, max = 0 }
        P.scopes[name] = s
    end
    return s
end

-- --------------------------------------------------------------------------
-- Scope timing
-- --------------------------------------------------------------------------
-- The no-op forms are what Data.lua installs at load time, so call sites in
-- Core/Commands can call these unconditionally.  Enabling swaps in the real
-- implementations; disabling swaps the no-ops back.

local function noop() end

-- Snapshot of the API counters, used to attribute calls to one slow event.
local function copy_api_counts()
    local out = {}
    for k, v in pairs(P.api) do out[k] = v end
    return out
end

local function api_delta(before)
    local out, total = {}, 0
    for k, v in pairs(P.api) do
        local d = v - (before[k] or 0)
        if d > 0 then
            out[k] = d
            total  = total + d
        end
    end
    return out, total
end

local function record_sample(name, dur, before)
    local threshold = tonumber(map.configs.profile_sample_threshold) or 0.05
    if dur < threshold then return end
    local calls, total = api_delta(before)
    P.samples[#P.samples + 1] = {
        name  = name,
        dur   = dur,
        api   = calls,
        total = total,
    }
    -- Keep the worst N.  Sorting a <=26-entry list per slow event is free
    -- next to the event that just took 50ms+.
    table.sort(P.samples, function(a, b) return a.dur > b.dur end)
    local maxKeep = tonumber(map.configs.profile_max_samples) or 25
    for i = #P.samples, maxKeep + 1, -1 do
        P.samples[i] = nil
    end
end

local function prof_enter(name)
    local depth = #stack + 1
    stack[depth] = {
        name  = name,
        t0    = now(),
        child = 0,
        api   = (depth == 1) and copy_api_counts() or nil,
    }
end

local function prof_exit()
    local depth = #stack
    if depth < 1 then return end
    local frame  = stack[depth]
    stack[depth] = nil

    local dur = now() - frame.t0
    local s   = scope_stats(frame.name)
    s.calls   = s.calls + 1
    s.total   = s.total + dur
    s.self    = s.self + (dur - frame.child)
    if dur > s.max then s.max = dur end

    if depth > 1 then
        local parent = stack[depth - 1]
        parent.child = parent.child + dur
    elseif frame.api then
        record_sample(frame.name, dur, frame.api)
    end
end

-- --------------------------------------------------------------------------
-- Mudlet API counters
-- --------------------------------------------------------------------------
-- Return arity has to be preserved exactly, so each wrapper names its results
-- rather than forwarding a packed table: `unpack{}` on a call that returned a
-- leading nil would drop the trailing results, and getRoomCoordinates returning
-- nil for an unplaced room is a case the mapper tests for constantly.
--
-- Everything not listed here returns a single value (or nothing, for the
-- setters, where returning one extra nil is unobservable — no call site in
-- map/ uses a setter's result).
local API_ARITY = {
    getRoomCoordinates = 3,
    updateMap          = 0,
    centerview         = 0,
}

local API_NAMES = {
    -- reads
    "getRoomCoordinates", "getRoomsByPosition", "getAreaRooms", "getRooms",
    "getRoomIDbyHash", "getRoomHashByID", "getRoomName", "getRoomArea",
    "getRoomExits", "getRoomUserData", "getAllRoomUserData", "getRoomEnv",
    "getRoomChar", "getExitStubs1", "getSpecialExitsSwap", "getPlayerRoom",
    "roomLocked", "getAreaTableSwap", "getAreaRoomsCount", "getPath",
    -- writes
    "setRoomCoordinates", "setRoomArea", "setRoomName", "setRoomIDbyHash",
    "setRoomUserData", "clearRoomUserDataItem", "setRoomEnv", "setRoomChar",
    "setExit", "connectExitStub", "setExitStub", "addRoom", "deleteRoom",
    "createRoomID", "lockRoom", "setGridMode", "updateMap", "centerview",
}

-- name -> the function that was in place before we wrapped it.  Held on the
-- profile table, not in a file-local, so a script reload can still find it:
-- reloading re-runs this chunk with a fresh local but leaves the wrapped
-- globals in place, and without the originals they could never be restored.
P._api_originals = P._api_originals or {}
local originals  = P._api_originals

local function count(name)
    P.api[name] = (P.api[name] or 0) + 1
end

-- Time spent inside one Mudlet call.  Worth measuring separately from the
-- counts because the two answer different questions: counts find a loop that
-- issues O(area) round-trips, timing finds a single call that is O(area)
-- *inside* Mudlet.  A scope with three API calls and 400ms of self time is the
-- second kind, and no amount of counting would show which of the three it was.
local function add_time(name, dt)
    local t = P.apiTime[name]
    if t == nil then
        P.apiTime[name] = { total = dt, max = dt }
        return
    end
    t.total = t.total + dt
    if dt > t.max then t.max = dt end
end

local function make_wrapper(name, fn, arity)
    if arity == 0 then
        return function(...)
            count(name)
            local t0 = now()
            fn(...)
            add_time(name, now() - t0)
        end
    elseif arity == 3 then
        return function(...)
            count(name)
            local t0 = now()
            local a, b, c = fn(...)
            add_time(name, now() - t0)
            return a, b, c
        end
    end
    return function(...)
        count(name)
        local t0 = now()
        local a = fn(...)
        add_time(name, now() - t0)
        return a
    end
end

local function install_api_wrappers()
    for _i, name in ipairs(API_NAMES) do
        local fn = _G[name]
        -- `originals[name] ~= nil` means a previous enable is still installed
        -- (a script reload with profiling left on).  Wrapping the wrapper would
        -- double every count and make the restore below leak a layer, so skip.
        if type(fn) == "function" and originals[name] == nil then
            originals[name] = fn
            _G[name] = make_wrapper(name, fn, API_ARITY[name] or 1)
        end
    end
end

local function remove_api_wrappers()
    for name, fn in pairs(originals) do
        _G[name] = fn
        originals[name] = nil
    end
end

-- --------------------------------------------------------------------------
-- Function wrappers
-- --------------------------------------------------------------------------
-- Names are resolved at enable time rather than hardcoded into the modules, so
-- adding a scope costs one line here and nothing on the hot path when off.
-- A name that does not resolve to a function is reported instead of silently
-- skipped: a typo here would otherwise look like "that function is never hot".

-- { container, key, scope name }
local function targets()
    return {
        -- Helpers: room placement
        { _, "stretch_area_for_new_room",     "stretch_area" },
        { _, "move_room_to_expected_position", "move_to_expected" },
        { _, "set_room_coordinates",          "set_coords" },
        { _, "set_room_area",                 "set_area" },
        { _, "delete_room",                   "delete_room" },
        { _, "add_room",                      "add_room" },
        { _, "find_free_cell_near",           "find_free_cell" },
        -- Helpers: caches and indexes
        { _, "build_pos_cache",               "build_pos_cache" },
        { _, "build_area_index",              "build_area_index" },
        { _, "rooms_at_position",             "rooms_at_position" },
        { _, "resolve_room_id_by_hash",       "resolve_by_hash" },
        { _, "find_real_room_to_adopt",       "find_real_to_adopt" },
        { _, "rooms_with_name",               "rooms_with_name" },
        { _, "get_estimated_area_room_count", "area_room_count" },
        -- Helpers: bulk passes
        { map, "dedupe_area_by_hash",         "dedupe_area" },
        { _, "resolve_room_overlaps",         "resolve_overlaps" },
        { _, "snap_vertical_pair",            "snap_vertical" },
        { _, "build_reverse_exit_index",      "reverse_exit_index" },
        { _, "merge_duplicate_room",          "merge_duplicate" },
        { _, "audit_layout_anomalies",        "audit_anomalies" },
        { _, "exit_consistency_score",        "consistency_score" },
        -- Layout
        { _, "create_neighbors_for_current_room", "create_neighbors" },
        { _, "reconcile_connected_rooms",     "reconcile" },
        { _, "flatten_cardinal_connected_rooms", "flatten" },
        { _, "realign_displaced_room",        "realign" },
        { _, "apply_elevation_anchor",        "elevation_anchor" },
        { _, "sky_altitude",                  "sky_altitude" },
        { _, "apply_anchor_translation",      "anchor_translate" },
        { _, "apply_elevation_planes",        "elevation_planes" },
        { _, "finish_layout_repair",          "layout_tail" },
        -- Core / Commands entry points
        { map, "eventHandler",                "gmcp_event" },
        { map, "make_room",                   "make_room" },
        { _, "continue_walk",                 "continue_walk" },
        { map, "travel_to_selected_room",     "travel_to_room" },
        -- Bulk commands: not on the movement hot path, but the same scopes
        -- above break them down, so `map normalize` can be profiled too.
        { map, "normalize_room_layout",       "normalize" },
        { map, "normalize_all_areas",         "normalize_all" },
    }
end

-- key -> { container, key, original } for everything we replaced.
local wrapped = {}

local function install_fn_wrappers()
    local missing = {}
    for _i, t in ipairs(targets()) do
        local container, key, label = t[1], t[2], t[3]
        local fn = container[key]
        if type(fn) ~= "function" then
            missing[#missing + 1] = key
        elseif wrapped[label] == nil then
            wrapped[label] = { container = container, key = key, fn = fn }
            container[key] = function(...)
                -- Errors have to unwind the scope stack or every later reading
                -- is attributed to a frame that never closed.  The mapper runs
                -- most of this under pcall already, so an error here is a live
                -- possibility rather than a theoretical one.  Unwinding to the
                -- entry depth (rather than popping one frame) also cleans up
                -- after the manual _.prof_enter sites in Core/Commands, which
                -- have no pcall of their own.
                local depth = #stack
                prof_enter(label)
                local ok, a, b, c, d = pcall(fn, ...)
                while #stack > depth do prof_exit() end
                if not ok then error(a, 0) end
                return a, b, c, d
            end
        end
    end
    return missing
end

local function remove_fn_wrappers()
    for label, w in pairs(wrapped) do
        w.container[w.key] = w.fn
        wrapped[label] = nil
    end
end

-- --------------------------------------------------------------------------
-- Control
-- --------------------------------------------------------------------------

function P.reset()
    P.scopes  = {}
    P.api     = {}
    P.apiTime = {}
    P.samples = {}
    P.started = P.enabled and now() or nil
    stack     = {}
end

function P.on()
    if P.enabled then
        cecho("<yellow>map profile: already on.\n")
        return
    end
    P.reset()
    _.prof_enter = prof_enter
    _.prof_exit  = prof_exit
    install_api_wrappers()
    local missing = install_fn_wrappers()
    P.enabled = true
    P.started = now()
    cecho("<green>map profile: on.\n")
    if #missing > 0 then
        cecho("<yellow>map profile: not found, so not instrumented: "
            .. table.concat(missing, ", ") .. "\n")
    end
    cecho("<grey>Walk into unmapped rooms, then: map profile report\n")
end

function P.off()
    if not P.enabled then
        cecho("<yellow>map profile: already off.\n")
        return
    end
    remove_fn_wrappers()
    remove_api_wrappers()
    _.prof_enter = noop
    _.prof_exit  = noop
    stack        = {}
    P.enabled    = false
    cecho("<green>map profile: off. Data kept — 'map profile report' still works.\n")
end

function P.status()
    cecho("<cyan>map profile: " .. (P.enabled and "<green>on" or "<red>off") .. "<reset>\n")
    if P.started then
        cecho(string.format("<grey>  elapsed: %.1fs, scopes: %d, samples kept: %d\n",
            now() - P.started, (function()
                local n = 0
                for _k in pairs(P.scopes) do n = n + 1 end
                return n
            end)(), #P.samples))
    end
    cecho(string.format("<grey>  sample threshold: %.0fms, max samples: %d\n",
        (tonumber(map.configs.profile_sample_threshold) or 0.05) * 1000,
        tonumber(map.configs.profile_max_samples) or 25))
end

-- --------------------------------------------------------------------------
-- Report
-- --------------------------------------------------------------------------

local function sorted_pairs(t, key)
    local list = {}
    for k, v in pairs(t) do list[#list + 1] = { k = k, v = v } end
    table.sort(list, function(a, b) return key(a.v) > key(b.v) end)
    return list
end

local function ms(seconds) return seconds * 1000 end

function P.report(limit)
    limit = tonumber(limit) or 12

    cecho("\n<white>=== map profile ===<reset>\n")
    P.status()

    -- Scopes, ranked by self time: the function actually burning the clock,
    -- not merely the one that contains it.
    local scopes = sorted_pairs(P.scopes, function(s) return s.self end)
    if #scopes == 0 then
        cecho("<yellow>No scope data. Was profiling on while you moved?\n")
    else
        cecho("\n<cyan>Scopes by self time<reset>\n")
        cecho(string.format("<grey>%-22s %8s %10s %10s %9s %9s\n",
            "scope", "calls", "self ms", "total ms", "self/call", "max ms"))
        for i = 1, math.min(limit, #scopes) do
            local e, s = scopes[i], scopes[i].v
            cecho(string.format("<white>%-22s <reset>%8d %10.1f %10.1f %9.2f %9.1f\n",
                e.k, s.calls, ms(s.self), ms(s.total),
                s.calls > 0 and ms(s.self) / s.calls or 0, ms(s.max)))
        end
    end

    -- API calls, ranked by the time they spent inside Mudlet.  Each of these is
    -- a C++ round-trip.  Two different failures show up here: a large count with
    -- a small ms/call is a Lua loop issuing O(area) round-trips, while a small
    -- count with a large ms/call is one call that is O(area) inside Mudlet.
    -- Only the first kind can be fixed by caching on this side.
    local api = sorted_pairs(P.apiTime, function(t) return t.total end)
    if #api > 0 then
        local grandCalls, grandTime = 0, 0
        for _i, e in ipairs(api) do
            grandCalls = grandCalls + (P.api[e.k] or 0)
            grandTime  = grandTime + e.v.total
        end
        cecho(string.format("\n<cyan>Mudlet API by time<reset> <grey>(%d calls, %.0fms total)\n",
            grandCalls, ms(grandTime)))
        cecho(string.format("<grey>%-24s %8s %10s %9s %9s\n",
            "api", "calls", "total ms", "ms/call", "max ms"))
        for i = 1, math.min(limit, #api) do
            local e = api[i]
            local n = P.api[e.k] or 0
            cecho(string.format("<white>%-24s <reset>%8d %10.1f %9.2f %9.1f\n",
                e.k, n, ms(e.v.total), n > 0 and ms(e.v.total) / n or 0, ms(e.v.max)))
        end
    end

    -- The slow events themselves, with what each one spent its calls on.
    if #P.samples > 0 then
        cecho(string.format("\n<cyan>Slowest events<reset> <grey>(over %.0fms)\n",
            (tonumber(map.configs.profile_sample_threshold) or 0.05) * 1000))
        for i = 1, math.min(limit, #P.samples) do
            local s = P.samples[i]
            local calls = sorted_pairs(s.api, function(v) return v end)
            local parts = {}
            for j = 1, math.min(4, #calls) do
                parts[#parts + 1] = calls[j].k .. " x" .. calls[j].v
            end
            cecho(string.format("<white>%7.0fms <reset>%-16s <grey>%d api calls: %s\n",
                ms(s.dur), s.name, s.total, table.concat(parts, ", ")))
        end
    end
    cecho("\n")
end

-- --------------------------------------------------------------------------
-- Reload recovery
-- --------------------------------------------------------------------------
-- A script reload re-runs every map/ chunk, which redefines the very functions
-- install_fn_wrappers replaced — so those wrappers are already gone by the time
-- this chunk runs, and `wrapped` above is a fresh empty table that could never
-- restore them.  The API globals are the opposite case: nothing redefines them,
-- so they are still wrapped, and P._api_originals is what makes the restore
-- possible.  Put both halves back to a known-off state and say so, rather than
-- leaving a session half-instrumented and reporting nonsense.
if P.enabled then
    remove_api_wrappers()
    P.enabled    = false
    _.prof_enter = noop
    _.prof_exit  = noop
    stack        = {}
    if type(cecho) == "function" then
        cecho("<yellow>map profile: turned off by script reload. "
            .. "Collected data kept; run 'map profile on' to resume.\n")
    end
end

-- Dispatch for the `map profile ...` alias.
function P.command(arg)
    arg = type(arg) == "string" and arg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    if arg == "" or arg == "status" then
        P.status()
    elseif arg == "on" or arg == "start" then
        P.on()
    elseif arg == "off" or arg == "stop" then
        P.off()
    elseif arg == "reset" then
        P.reset()
        cecho("<green>map profile: counters reset.\n")
    elseif arg:match("^report") then
        P.report(arg:match("^report%s+(%d+)$"))
    else
        cecho("<yellow>Usage: map profile [on|off|reset|report [N]|status]\n")
    end
end
