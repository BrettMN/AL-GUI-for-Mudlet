-- De-duplicate rooms in the current area that share the same hash,
-- then run the full normalize pipeline (reconcile + anchor align).
map.normalize_room_layout()
