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
    if not GUI or ALUI.uiDisabled then
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

ALUI.GUI.runResizeOperations = runResizeOperations

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
