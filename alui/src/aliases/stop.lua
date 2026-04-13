if not (map and type(map.stop_auto_walk) == "function" and map.stop_auto_walk()) then
    send("stop")
end
