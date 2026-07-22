local function parseNum(s) return s and tonumber((s:gsub(",", ""))) or nil end
-- Arguments: [maxMoves [maxPasses]]
-- With no arguments the move cap auto-scales to the area size, so large areas
-- normalise fully instead of bailing out after the static default (~5000
-- moves).  Pass a value to override, e.g. "map normalize 200" to cap the work.
local maxMoves  = parseNum(matches[2])
local maxPasses = parseNum(matches[3])
map.normalize_room_layout(maxPasses, maxMoves)
