local profileName = getProfileName()

local RESIZE_TIMER_DELAY = 0.1

ALUI = ALUI or {}
ALUI.GUI = ALUI.GUI or {}
ALUI.GUI.Events = ALUI.GUI.Events or {}
ALUI.GUI.Timers = ALUI.GUI.Timers or {}
ALUI.GUI.Style = ALUI.GUI.Style or {}

ALUI.GUI.Timers.lastResizeTime = ALUI.GUI.Timers.lastResizeTime or 0

local function cleanupTimers()
    local RM = ALUI and ALUI.ResourceManager
    local GUI = ALUI and ALUI.GUI

    if RM then
        RM.cleanupByCategory("resize")
        RM.cleanupByCategory("ui")
    elseif GUI and GUI.Timers and GUI.Timers.resize then
        killTimer(GUI.Timers.resize)
        GUI.Timers.resize = nil
    end

    if GUI and GUI.Timers then
        GUI.Timers.lastResizeTime = 0
    end
end

ALUI.GUI.cleanupTimers = cleanupTimers

local function runResizeOperations()
    local GUI = ALUI and ALUI.GUI
    if not GUI then
        return
    end

    -- setBackground() normalizes and clamps GUI.Layout for the new window size,
    -- so it must run before setBorders() consumes those values. resizeBoxes()
    -- repositions every box and its contents; setBoxes() is a constructor and
    -- must not run here (it would rebuild every widget on each resize).
    if GUI.setBackground then
        GUI.setBackground()
    end
    if GUI.setBorders then
        GUI.setBorders()
    end
    if GUI.resizeBoxes then
        GUI.resizeBoxes()
    end
    if GUI.Logic and GUI.Logic.StyleUpdate then
        GUI.Logic.StyleUpdate()
    end
end

-- Trailing-edge debounce: every event reschedules the pending run, so the last
-- event of a drag always gets one. A leading-edge throttle here can swallow that
-- final event and leave the layout sized for an intermediate window size.
local function resizeHandler()
    local RM = ALUI and ALUI.ResourceManager
    local GUI = ALUI and ALUI.GUI
    if not GUI or not GUI.Timers then
        return
    end

    GUI.Timers.lastResizeTime = getEpoch()

    if RM then
        RM.createTimer("resizeOperation", RESIZE_TIMER_DELAY, function()
            local success, errorMsg = pcall(runResizeOperations)
            if not success then
                echo(string.format("Error during resize operations: %s\n", tostring(errorMsg)))
            end
        end, false, "resize")
    else
        if GUI.Timers.resize then
            killTimer(GUI.Timers.resize)
            GUI.Timers.resize = nil
        end

        GUI.Timers.resize = tempTimer(RESIZE_TIMER_DELAY, function()
            GUI.Timers.resize = nil
            local success, errorMsg = pcall(runResizeOperations)
            if not success then
                echo(string.format("Error during resize operations: %s\n", tostring(errorMsg)))
            end
        end)
    end
end

if ALUI.GUI.Events.resize then
    stopNamedEventHandler(profileName, "ALUI.events.resize")
end

ALUI.GUI.Events.resize = registerNamedEventHandler(
    profileName,
    "ALUI.events.resize",
    "sysWindowResizeEvent",
    resizeHandler,
    false
)

function ALUI.disable()
    if ALUI.GUI.Events.resize then
        stopNamedEventHandler(profileName, "ALUI.events.resize")
        ALUI.GUI.Events.resize = nil
    end

    cleanupTimers()

    if ALUI.ResourceManager then
        ALUI.ResourceManager.cleanupAll()
    end

    local GUI = ALUI.GUI or {}
    local rootPanels = { "Left", "Right", "Top" }
    for _, key in ipairs(rootPanels) do
        local el = GUI[key]
        if el and type(el.hide) == "function" then
            pcall(function() el:hide() end)
        end
        if el and type(el.deleteSelf) == "function" then
            pcall(function() el:deleteSelf() end)
        end
        GUI[key] = nil
    end

    setBorderLeft(0)
    setBorderRight(0)
    setBorderTop(0)
    setBorderBottom(0)

    cecho("<green>ALUI disabled. Mudlet main window restored.\n")
    cecho("<dim_grey>To re-enable, reload the package or reconnect.\n")
end
