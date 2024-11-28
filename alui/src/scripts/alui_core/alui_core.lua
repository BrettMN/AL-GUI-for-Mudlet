--util funcs
function table.flip(tbl)
    local t = {}
    for k, v in pairs(tbl) do
        t[v] = k
    end
    return t
end

--end util funcs

alui = alui or {}

-- alui.menu_con = Adjustable.Container:new({
--     name = "Menu",
--     x = 0,
--     y = 0,
--     attached = "left",
--     width = "25%",
--     height = "5%",
-- })

-- alui.menu_button = Geyser.Label:new({
--     name = "popupLabel",
--     x = "0",
--     y = "0",
--     width = "100%",
--     height = "100%",
--     message = "<center>Menu</center>",
--     color = "gray",
--     fgColor = "white",
-- }, alui.menu_con)



-- alui.mapcon = Adjustable.Container:new({
--     name = "alui map con",
--     x = 0, y = '5%',
--     attached = "left",
--     width = "25%",
--     height = "45%",
-- })
-- alui.mapmini = Geyser.Mapper:new({
--     name = "alui map window",
--     x = 0, y = 0,
--     width = "100%",
--     height = "100%",
-- }, alui.mapcon)


-- GUI.Map_Container = Geyser.Container:new({
--     name = "GUI.Map_Container",
--     x = 0,
--     y = 0,
--     width = "100%",
--     height = "100%",
-- }, GUI.Box4)

-- GUI.Mapper = Geyser.Mapper:new({
--     name = "GUI.Mapper",
--     x = 0,
--     y = 0,
--     width = GUI.Map_Container:get_width(),   -- - 40,
--     height = GUI.Map_Container:get_height(), -- - 40,
-- }, GUI.Map_Container)

-- --the map's default background color is black, so lets blend it in...
-- GUI.Box1CSS = CSSMan.new(GUI.BoxCSS:getCSS())
-- GUI.Box1CSS:set("background-color", "black")
-- GUI.Box1:setStyleSheet(GUI.Box1CSS:getCSS())





-- alui.roomcon = Geyser.Container:new({
--     name = "alui room con",
--     x = 0,
--     y = "50%",
--     -- attached = "left",
--     width = "100%",
--     height = "100%",
-- }, GUI.Box5)

-- alui.roommini = Geyser.MiniConsole:new({
--     name = "alui room miniconsole",
--     x = 0,
--     y = 0,
--     width = "100%",
--     height = "100%",
--     color = "black",
--     autoWrap = true,
-- }, alui.roomcon)

-- alui.combatcon = Geyser.Container:new({
--     name = "alui combat con",
--     x = 0,
--     y = "75%",
--     -- attached = "left",
--     height = "100%",
--     width = "100%",
-- }, GUI.Box7)

-- alui.combatmini = Geyser.MiniConsole:new({
--     name = "alui combat console",
--     x = 0,
--     y = 0,
--     height = "100%",
--     width = "100%",
--     color = "black",
--     autoWrap = true,
-- }, alui.combatcon)











-- alui.surveycon = Adjustable.Container:new({
--     name = "alui survey con",
--     attached = "right",
--     x = "75%",
--     y = 0,
--     width = "25%",
--     height = "25%",
-- })

-- alui.surveymini = Geyser.MiniConsole:new({
--     name = "alui survey mini",
--     x = 0,
--     y = 0,
--     width = "100%",
--     height = "100%",
--     color = "black",
-- }, alui.surveycon)

-- alui.stylecon = Adjustable.Container:new({
--     name = "alui style con",
--     x = "75%",
--     y = 0,
--     attached = "right",
--     width = "25%",
--     height = "25%",
-- })

-- alui.stylemini = alui.stylemini or Geyser.MiniConsole:new({
--     name = "alui style console",
--     attached = "right",
--     x = 0,
--     y = 0,
--     width = "100%",
--     height = "100%",
--     color = "black",
-- }, alui.stylecon)

-- alui.chatcon = Adjustable.Container:new({
--     name = "alui chat con",
--     x = "75%",
--     y = "25%",
--     attached = "right",
--     width = "25%",
--     height = "75%",
-- })








-- -- Function to create and display the popup menu
-- function showPopupMenu()
--     local menu = Geyser.UserWindow:new({
--         name = "popupMenu",
--         x = "50%",
--         y = "55%",
--         width = "10%",
--         height = "15%",
--         color = "black",
--     })

--     local menuItem1 = Geyser.Label:new({
--         name = "menuItem1",
--         x = 0,
--         y = 0,
--         width = "100%",
--         height = "33%",
--         message = "<center>Option 1</center>",
--         color = "gray",
--         fgColor = "white",
--     }, menu)

--     local menuItem2 = Geyser.Label:new({
--         name = "menuItem2",
--         x = 0,
--         y = "33%",
--         width = "100%",
--         height = "33%",
--         message = "<center>Option 2</center>",
--         color = "gray",
--         fgColor = "white",
--     }, menu)

--     local menuItem3 = Geyser.Label:new({
--         name = "menuItem3",
--         x = 0,
--         y = "66%",
--         width = "100%",
--         height = "33%",
--         message = "<center>Option 3</center>",
--         color = "gray",
--         fgColor = "white",
--     }, menu)

--     -- Define actions for menu items
--     menuItem1:setClickCallback(function()
--         echo("Option 1 selected\n")
--         menu:hide()
--     end)

--     menuItem2:setClickCallback(function()
--         echo("Option 2 selected\n")
--         menu:hide()
--     end)

--     menuItem3:setClickCallback(function()
--         echo("Option 3 selected\n")
--         menu:hide()
--     end)
-- end

-- -- Set the click callback for the label to show the popup menu
-- alui.menu_button:setClickCallback(showPopupMenu)
