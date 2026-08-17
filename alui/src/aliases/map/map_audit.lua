-- Read-only anomaly report for the current (or named) area.
-- Accepts "map audit", "map audit <area>", "map audit <N>", "map audit <area> <N>".
local arg = matches and matches[2]
if type(arg) == "string" then
    arg = arg:match("^%s*(.-)%s*$")
    if arg == "" then arg = nil end
end

local limit
if arg then
    local head, tail = arg:match("^(.-)%s+(%d+)$")
    if head and head ~= "" then
        arg, limit = head, tonumber(tail)
    elseif arg:match("^%d+$") then
        arg, limit = nil, tonumber(arg)
    end
end

map.audit_layout(arg, limit)
