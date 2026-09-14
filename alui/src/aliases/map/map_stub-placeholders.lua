-- Replaces placeholder rooms in the current (or named) area with exit stubs.
local areaArg = matches and matches[2]
if type(areaArg) == "string" and areaArg:match("^%s*$") then
    areaArg = nil
end
map.stub_placeholders(areaArg)
