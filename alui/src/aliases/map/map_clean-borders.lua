-- Deletes the legacy border marker rooms in the current (or named) area.
local areaArg = matches and matches[2]
if type(areaArg) == "string" and areaArg:match("^%s*$") then
    areaArg = nil
end
map.clean_border_markers(areaArg)
