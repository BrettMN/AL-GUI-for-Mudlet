local action = matches[2] and matches[2] ~= "" and matches[2] or nil
local category = matches[3] and matches[3] ~= "" and matches[3] or nil
local key = matches[4] and matches[4] ~= "" and matches[4] or nil
local value = matches[5] and matches[5] ~= "" and matches[5] or nil

if ALUI and ALUI.ConfigCommands and type(ALUI.ConfigCommands.handle) == "function" then
    ALUI.ConfigCommands.handle(action, category, key, value)
    return
end

local normalized = action and string.lower(action) or nil

local Config = ALUI and ALUI.Config
if not Config then
    if normalized == "path" or normalized == "where" then
        local home = getMudletHomeDir()
        cecho(("<cyan>Config file:<white> %s\n"):format(tostring(home .. "/alui_config.json")))
        cecho(("<cyan>Backup file:<white> %s\n"):format(tostring(home .. "/alui_config_backup.json")))
        cecho(("<cyan>Mudlet home:<white> %s\n"):format(tostring(home)))
    else
        cecho("<red>ALUI Config is not loaded yet.\n")
    end
    return
end

if normalized == "path" or normalized == "where" then
    local paths = Config.getPaths and Config.getPaths() or Config.paths
    if paths then
        cecho(("<cyan>Config file:<white> %s\n"):format(tostring(paths.config)))
        cecho(("<cyan>Backup file:<white> %s\n"):format(tostring(paths.backup)))
        cecho(("<cyan>Mudlet home:<white> %s\n"):format(tostring(paths.home)))
    else
        cecho("<red>Config path information unavailable.\n")
    end
elseif normalized == "save" then
    if type(Config.save) == "function" then
        Config.save()
        cecho("<green>Configuration saved to file\n")
    end
elseif normalized == "reload" then
    if type(Config.load) == "function" then
        Config.load()
        cecho("<green>Configuration reloaded from file\n")
    end
else
    cecho("<red>Config command system not fully loaded yet. Try again in a second.\n")
end
