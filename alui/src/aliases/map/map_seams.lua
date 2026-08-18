-- Close every seam in the current (or named) area that can be closed.
local areaArg = matches and matches[2]
if type(areaArg) == "string" then
    areaArg = areaArg:match("^%s*(.-)%s*$")
    if areaArg == "" then areaArg = nil end
end
map.close_area_seams(areaArg)
