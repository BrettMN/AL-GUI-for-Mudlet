-- Test determinism of map recalculate
local numRuns = matches[2] and tonumber(matches[2]) or 5
map.test_recalculate_determinism(numRuns)
