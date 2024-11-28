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
  height = "20%",
}, GUI.Right)
GUI.Box1:setStyleSheet(GUI.BoxCSS:getCSS())
-- GUI.Box1:echo("<center>GUI.Box1")

GUI.Box2 = Geyser.Label:new({
  name = "GUI.Box2",
  x = 0,
  y = "20%",
  width = "100%",
  height = "40%",
}, GUI.Right)
GUI.Box2:setStyleSheet(GUI.BoxCSS:getCSS())
GUI.Box2:echo("<center>GUI.Box2")

GUI.Box3 = Geyser.Label:new({
  name = "GUI.Box3",
  x = 0,
  y = "60%",
  width = "100%",
  height = "40%",
}, GUI.Right)
GUI.Box3:setStyleSheet(GUI.BoxCSS:getCSS())
GUI.Box3:echo("<center>GUI.Box3")

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







GUI.Style_Container = Geyser.Container:new({
  name = "alui style con",
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
}, GUI.Box1)

-- alui.stylemini = alui.stylemini or Geyser.MiniConsole:new({
--   name = "alui style console",
--   x = Gui_Padding,
--   y = Gui_Padding,
--   height = GUI.Style_Container:get_height() - (Gui_Padding * 2),
--   width = GUI.Style_Container:get_width() - (Gui_Padding * 2),
--   color = "black",
-- }, GUI.Style_Container)

GUI.GaugeBackCSS = CSSMan.new([[
  background-color: rgba(0,0,0,0);
  border-style: solid;
  border-color: white;
  border-width: 1px;
  border-radius: 5px;
  margin: 5px;
]])

GUI.GaugeFrontCSS = CSSMan.new([[
  background-color: rgba(0,0,0,0);
  border-style: solid;
  border-color: white;
  border-width: 1px;
  border-radius: 5px;
  margin: 5px;
]])


GUI.Style_VBox = Geyser.VBox:new({
  name = "alui style vbox",
  x = Gui_Padding,
  y = Gui_Padding,
  width = GUI.Style_Container:get_width() - (Gui_Padding * 2),
  height = GUI.Style_Container:get_height() - (Gui_Padding * 2),
}, GUI.Style_Container)


local Style_HBox_Height = "20%"


GUI.Style_HBox_Aim_Control = Geyser.HBox:new({
  name = "alui style hbox1",
  width = "100%",
  height = Style_HBox_Height,
}, GUI.Style_VBox)

GUI.Style_HBox_Offensive_Dodge = Geyser.HBox:new({
  name = "alui style hbox2",
  width = "100%",
  height = Style_HBox_Height,
}, GUI.Style_VBox)

GUI.Style_HBox_Darring_Parry = Geyser.HBox:new({
  name = "alui style hbox3",
  width = "100%",
  height = Style_HBox_Height,
}, GUI.Style_VBox)

GUI.Style_HBox_Power_Speed = Geyser.HBox:new({
  name = "alui style hbox4",
  width = "100%",
  height = Style_HBox_Height,
}, GUI.Style_VBox)

GUI.Style_HBox_Attack_Defense = Geyser.HBox:new({
  name = "alui style hbox5",
  width = "100%",
  height = Style_HBox_Height,
}, GUI.Style_VBox)







local Style_Button_Width = "20%"
local Style_Gauge_Width = "60%"

GUI.Style_Aim_Increase = Geyser.Button:new({
  name = "alui style aim increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Aim_Control)
GUI.Style_Aim_Increase:echo("<center>Aim")

GUI.Style_Gauge_Aim_Control = Geyser.Gauge:new({
  name = "alui style gauge aim control",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Aim_Control)

GUI.Style_Control_Increase = Geyser.Button:new({
  name = "alui style control increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Aim_Control)

GUI.Style_Control_Increase:echo("<center>Control")


GUI.Style_Gauge_Aim_Control:setValue(5, 10)

GUI.GaugeFrontCSS:set("background-color", "red")

GUI.GaugeBackCSS:set("background-color", "green")
GUI.Style_Gauge_Aim_Control.back:setStyleSheet(GUI.GaugeBackCSS:getCSS())
GUI.Style_Gauge_Aim_Control.front:setStyleSheet(GUI.GaugeFrontCSS:getCSS())

GUI.Style_Aim_Increase:setClickCallback(function()
  send('increase aim some', false)
end)
GUI.Style_Control_Increase:setClickCallback(function()
  send('increase control some', false)
end)






GUI.Style_Offensive_Increase = Geyser.Button:new({
  name = "alui style offensive increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Offensive_Dodge)
GUI.Style_Offensive_Increase:echo("<center>Offensive")

GUI.Style_Gauge_Offensive_Dodge = Geyser.Gauge:new({
  name = "alui style gauge offensive dodge",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Offensive_Dodge)

GUI.Style_Dodge_Increase = Geyser.Button:new({
  name = "alui style control dodge",
  width = Style_Button_Width,
}, GUI.Style_HBox_Offensive_Dodge)

GUI.Style_Dodge_Increase:echo("<center>Dodge")


GUI.Style_Gauge_Offensive_Dodge:setValue(5, 10)

GUI.GaugeFrontCSS:set("background-color", "yellow")

GUI.GaugeBackCSS:set("background-color", "blue")
GUI.Style_Gauge_Offensive_Dodge.back:setStyleSheet(GUI.GaugeBackCSS:getCSS())
GUI.Style_Gauge_Offensive_Dodge.front:setStyleSheet(GUI.GaugeFrontCSS:getCSS())

GUI.Style_Offensive_Increase:setClickCallback(function()
  send('increase offensive some', false)
end)
GUI.Style_Dodge_Increase:setClickCallback(function()
  send('increase dodge some', false)
end)





GUI.Style_Daring_Increase = Geyser.Button:new({
  name = "alui style daring increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Darring_Parry)

GUI.Style_Daring_Increase:echo("<center>Daring")

GUI.Style_Gauge_Daring_Parry = Geyser.Gauge:new({
  name = "alui style gauge daring parry",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Darring_Parry)

GUI.Style_Parry_Increase = Geyser.Button:new({
  name = "alui style parry increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Darring_Parry)

GUI.Style_Parry_Increase:echo("<center>Parry")


GUI.Style_Gauge_Daring_Parry:setValue(5, 10)

GUI.GaugeFrontCSS:set("background-color", "purple")

GUI.GaugeBackCSS:set("background-color", "orange")

GUI.Style_Gauge_Daring_Parry.back:setStyleSheet(GUI.GaugeBackCSS:getCSS())
GUI.Style_Gauge_Daring_Parry.front:setStyleSheet(GUI.GaugeFrontCSS:getCSS())

GUI.Style_Daring_Increase:setClickCallback(function()
  send('increase daring some', false)
end)

GUI.Style_Parry_Increase:setClickCallback(function()
  send('increase parry some', false)
end)





GUI.Style_Power_Increase = Geyser.Button:new({
  name = "alui style power increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Power_Speed)

GUI.Style_Power_Increase:echo("<center>Power")

GUI.Style_Gauge_Power_Speed = Geyser.Gauge:new({
  name = "alui style gauge power speed",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Power_Speed)

GUI.Style_Speed_Increase = Geyser.Button:new({
  name = "alui style speed increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Power_Speed)

GUI.Style_Speed_Increase:echo("<center>Speed")


GUI.Style_Gauge_Power_Speed:setValue(5, 10)

GUI.GaugeFrontCSS:set("background-color", "green")

GUI.GaugeBackCSS:set("background-color", "red")

GUI.Style_Gauge_Power_Speed.back:setStyleSheet(GUI.GaugeBackCSS:getCSS())

GUI.Style_Gauge_Power_Speed.front:setStyleSheet(GUI.GaugeFrontCSS:getCSS())

GUI.Style_Power_Increase:setClickCallback(function()
  send('increase power some', false)
end)

GUI.Style_Speed_Increase:setClickCallback(function()
  send('increase speed some', false)
end)





GUI.Style_Attack_Increase = Geyser.Button:new({
  name = "alui style attack increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Attack_Defense)

GUI.Style_Attack_Increase:echo("<center>Attack")

GUI.Style_Gauge_Attack_Defense = Geyser.Gauge:new({
  name = "alui style gauge attack defense",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Attack_Defense)

GUI.Style_Defense_Increase = Geyser.Button:new({
  name = "alui style defense increase",
  width = Style_Button_Width,
}, GUI.Style_HBox_Attack_Defense)

GUI.Style_Defense_Increase:echo("<center>Defense")


GUI.Style_Gauge_Attack_Defense:setValue(5, 10)

GUI.GaugeFrontCSS:set("background-color", "blue")

GUI.GaugeBackCSS:set("background-color", "yellow")

GUI.Style_Gauge_Attack_Defense.back:setStyleSheet(GUI.GaugeBackCSS:getCSS())

GUI.Style_Gauge_Attack_Defense.front:setStyleSheet(GUI.GaugeFrontCSS:getCSS())

GUI.Style_Attack_Increase:setClickCallback(function()
  send('increase attack some', false)
end)

GUI.Style_Defense_Increase:setClickCallback(function()
  send('increase defense some', false)
end)













GUI.Survey_Container = Geyser.Container:new({
  name = "alui survey con",
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
}, GUI.Box2)

alui.surveymini = Geyser.MiniConsole:new({
  name = "alui survey mini",
  x = Gui_Padding,
  y = Gui_Padding,
  height = GUI.Status_Container:get_height() - (Gui_Padding * 2),
  width = GUI.Status_Container:get_width() - (Gui_Padding * 2),

  color = "black",
}, GUI.Survey_Container)

GUI.Chat_Container = Geyser.Container:new({
  name = "alui chat con",
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
}, GUI.Box3)

alui.chat_cap = EMCO:new({
  name = "alui chat cap",
  allTab = true,
  consoles = { "All", "Say", "Chat", "Mentor", "Newbie" },
  x = Gui_Padding,
  y = Gui_Padding,
  width = GUI.Chat_Container:get_width() - (Gui_Padding * 2),
  height = GUI.Chat_Container:get_height() - (Gui_Padding * 2),
  scrollbars = true,
}, GUI.Chat_Container)
