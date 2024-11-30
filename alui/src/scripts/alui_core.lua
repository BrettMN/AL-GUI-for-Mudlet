--util funcs
function table.flip(tbl)
    local t = {}
    for k, v in pairs(tbl) do
        t[v] = k
    end
    return t
end

--end util funcs

alui          = alui or {}
alui.style    = alui.style or {}
alui.status   = alui.status or {}
alui.health   = alui.health or {}
alui.bleeding = alui.bleeding or {}
