local action = matches[2] and matches[2] ~= "" and matches[2] or nil
local category = matches[3] and matches[3] ~= "" and matches[3] or nil
local key = matches[4] and matches[4] ~= "" and matches[4] or nil
local value = matches[5] and matches[5] ~= "" and matches[5] or nil

ALUI.ConfigCommands.handle(action, category, key, value)
