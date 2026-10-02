-- Replaces placeholder rooms in the current (or named) area with exit stubs.
-- "all [confirm]" sweeps the whole map instead.
local areaArg = matches and matches[2]
if type(areaArg) == "string" and areaArg:match("^%s*$") then
    areaArg = nil
end
local allArg = type(areaArg) == "string"
    and (areaArg:match("^%s*all%s*$") and "" or areaArg:match("^%s*all%s+(.-)%s*$"))
if allArg then
    map.stub_all_placeholders(allArg)
else
    map.stub_placeholders(areaArg)
end
