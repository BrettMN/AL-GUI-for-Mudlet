local function parseNum(s) return s and tonumber((s:gsub(",", ""))) or nil end
-- Arguments: [maxMoves [maxPasses]]
-- Single argument is maxMoves so "map normalize 7000000" raises the move cap.
local maxMoves  = parseNum(matches[2])
local maxPasses = parseNum(matches[3])
map.normalize_room_layout(maxPasses, maxMoves)
