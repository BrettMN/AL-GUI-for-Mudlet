-- logEvent: debug utility — disabled by default.
-- Enable via: Config.set("debug.log_all_events", true)
-- When enabled, events are batched and written to a single rolling file
-- at most once every 250 ms, instead of one file per event.

local LOG_DEBOUNCE_MS = 0.25   -- seconds between flushes
local logQueue        = {}
local logFlushTimer   = nil
local logFilePath     = nil

local function isLoggingEnabled()
    local ok, cfg = pcall(function() return Config and Config.get("debug.log_all_events", false) end)
    return ok and cfg == true
end

local function flushLog()
    logFlushTimer = nil
    if #logQueue == 0 then return end

    if not logFilePath then
        logFilePath = getMudletHomeDir() .. "/alui/logs/events.log"
    end

    local file = io.open(logFilePath, "a")
    if file then
        for _, entry in ipairs(logQueue) do
            file:write(entry .. "\n")
        end
        file:close()
    end
    logQueue = {}
end

function logEvent(e)
    if not isLoggingEnabled() then return end

    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local gmcpStr   = ""
    if type(gmcp) == "table" then
        local ok, s = pcall(yajl.to_string, gmcp)
        gmcpStr = ok and s or "(encode error)"
    end
    logQueue[#logQueue + 1] = string.format("[%s] %s %s", timestamp, e, gmcpStr)

    if not logFlushTimer then
        logFlushTimer = tempTimer(LOG_DEBOUNCE_MS, flushLog)
    end
end

-- Register with ResourceManager if available
local RM = ALUI and ALUI.ResourceManager
if RM then
    local handlerId = registerAnonymousEventHandler("*", "logEvent")
    RM.registerEventHandler(
        "globalLogEvent",
        handlerId,
        "*",
        "logging"
    )
else
    registerAnonymousEventHandler("*", "logEvent")
end

-- Register with ALUI namespace if available
if ALUI and ALUI.GUI then
    ALUI.GUI.Logic = ALUI.GUI.Logic or {}
    ALUI.GUI.Logic.logEvent = logEvent
end
