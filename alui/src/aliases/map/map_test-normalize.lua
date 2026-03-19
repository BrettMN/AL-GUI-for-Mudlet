-- Test determinism of map normalize
local numRuns = matches[2] and tonumber(matches[2]) or 5
map.test_normalize_determinism(numRuns)
