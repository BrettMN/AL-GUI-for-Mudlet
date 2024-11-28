local EMCO = require("alui.emco")


GUI.BoxCSS = CSSMan.new([[
  background-color: rgba(0,0,0,100);
  border-style: solid;
  border-width: 1px;
  border-radius: 10px;
  border-color: white;
  margin: 10px;
]])

GUI.Box1 = Geyser.Label:new({
  name = "GUI.Box1",
  x = 0,
  y = 0,
  width = "100%",
  height = "50%",
}, GUI.Right)
GUI.Box1:setStyleSheet(GUI.BoxCSS:getCSS())
-- GUI.Box1:echo("<center>GUI.Box1")

GUI.Box2 = Geyser.Label:new({
  name = "GUI.Box2",
  x = 0,
  y = "50%",
  width = "100%",
  height = "50%",
}, GUI.Right)
GUI.Box2:setStyleSheet(GUI.BoxCSS:getCSS())
GUI.Box2:echo("<center>GUI.Box2")

-- GUI.Box3 = Geyser.Label:new({
--   name = "GUI.Box3",
--   x = "50%",
--   y = "50%",
--   width = "50%",
--   height = "50%",
-- }, GUI.Right)
-- GUI.Box3:setStyleSheet(GUI.BoxCSS:getCSS())
-- GUI.Box3:echo("<center>GUI.Box3")

GUI.Box4 = Geyser.Label:new({
  name = "GUI.Box4",
  x = "0%",
  y = "0%",
  width = "100%",
  height = "50%",
}, GUI.Left)
GUI.Box4:setStyleSheet(GUI.BoxCSS:getCSS())
-- GUI.Box4:echo("<center>GUI.Box4")

GUI.Box5 = Geyser.Label:new({
  name = "GUI.Box5-6",
  x = "0%",
  y = "50%",
  width = "100%",
  height = "25%",
}, GUI.Left)
GUI.Box5:setStyleSheet(GUI.BoxCSS:getCSS())
-- GUI.Box5:echo("<center>GUI.Box5")

-- GUI.Box6 = Geyser.Label:new({
--   name = "GUI.Box6",
--   x = "50%", y = "25%",
--   width = "50%",
--   height = "50%",
-- },GUI.Left)
-- GUI.Box6:setStyleSheet(GUI.BoxCSS:getCSS())
-- GUI.Box6:echo("<center>GUI.Box6")

GUI.Box7 = Geyser.Label:new({
  name = "GUI.Box7",
  x = "0%",
  y = "75%",
  width = "100%",
  height = "25%",
}, GUI.Left)
GUI.Box7:setStyleSheet(GUI.BoxCSS:getCSS())
-- GUI.Box7:echo("<center>GUI.Box7")



local Gui_Padding = 20



GUI.Map_Container = Geyser.Container:new({
  name = "GUI.Map_Container",
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
}, GUI.Box4)

GUI.Mapper = Geyser.Mapper:new({
  name = "GUI.Mapper",
  x = Gui_Padding,
  y = Gui_Padding,
  width = GUI.Map_Container:get_width() - (Gui_Padding * 2),
  height = GUI.Map_Container:get_height() - (Gui_Padding * 2),
}, GUI.Map_Container)

--the map's default background color is black, so lets blend it in...
GUI.Box1CSS = CSSMan.new(GUI.BoxCSS:getCSS())
GUI.Box1CSS:set("background-color", "black")
GUI.Box1:setStyleSheet(GUI.Box1CSS:getCSS())





GUI.Room_Container = Geyser.Container:new({
  name = "alui room con",
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
}, GUI.Box5)

alui.roommini = Geyser.MiniConsole:new({
  name = "alui room miniconsole",
  x = Gui_Padding,
  y = Gui_Padding,
  width = GUI.Room_Container:get_width() - (Gui_Padding * 2),
  height = GUI.Room_Container:get_height() - (Gui_Padding * 2),
  color = "black",
  autoWrap = true,
}, GUI.Room_Container)



GUI.Status_Container = Geyser.Container:new({
  name = "alui combat con",
  x = 0,
  y = 0,
  height = "100%",
  width = "100%",
}, GUI.Box7)

alui.combatmini = Geyser.MiniConsole:new({
  name = "alui combat console",
  x = Gui_Padding,
  y = Gui_Padding,
  height = GUI.Status_Container:get_height() - (Gui_Padding * 2),
  width = GUI.Status_Container:get_width() - (Gui_Padding * 2),
  color = "black",
  autoWrap = true,
}, GUI.Status_Container)








GUI.Survey_Container = Geyser.Container:new({
  name = "alui survey con",
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
}, GUI.Box1)

alui.surveymini = Geyser.MiniConsole:new({
  name = "alui survey mini",
  x = Gui_Padding,
  y = Gui_Padding,
  width = GUI.Survey_Container:get_width() - (Gui_Padding * 2),
  height = GUI.Survey_Container:get_height() - (Gui_Padding * 2),
  color = "black",
}, alui.surveycon)

-- alui.stylecon = Adjustable.Container:new({
--     name = "alui style con",
--     x = 0,
--     y = 0,
--     width = "100%",
--     height = "100%",
-- })

-- alui.stylemini = alui.stylemini or Geyser.MiniConsole:new({
--     name = "alui style console",

--     x = 0,
--     y = 0,
--     width = "100%",
--     height = "100%",
--     color = "black",
-- }, alui.stylecon)

alui.chatcon = Geyser.Container:new({
  name = "alui chat con",
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
}, GUI.Box2)

alui.chat_cap = EMCO:new({
  name = "alui chat cap",
  allTab = true,
  consoles = { "All", "Say", "Chat", "Mentor", "Newbie" },
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
  scrollbars = true,
}, alui.chatcon)
