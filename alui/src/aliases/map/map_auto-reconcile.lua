map.configs.auto_reconcile = not map.configs.auto_reconcile
echo("Auto-reconcile is now " .. (map.configs.auto_reconcile and "ON" or "OFF") .. ".\n")
if map.configs.auto_reconcile then
    echo("  Rooms will be repositioned automatically as you move.\n")
else
    echo("  Rooms will NOT be repositioned automatically. Use 'map normalize' to reposition manually.\n")
end
