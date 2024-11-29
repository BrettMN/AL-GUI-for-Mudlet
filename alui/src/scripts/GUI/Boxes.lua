local EMCO = require("alui.emco")




GUI.BoxCSS = CSSMan.new([[
  background-color: black;
  border-style: solid;
  border-width: 1px;
  border-radius: 10px;
  border-color: white;
  margin: 10px;
]])


-- GUI.GaugeBackCSS = CSSMan.new([[
--   background-color: rgba(0,0,0,0);
--   border-style: solid;
--   border-color: white;
--   border-width: 1px;
--   border-radius: 1px;
--   margin: 5px;
-- ]])

GUI.GaugeBackCSS = CSSMan.new([[
  background-color: rgba(0,0,0,0);
  margin-top: 5px;
  margin-bottom: 5px;
  border-style: solid;
  border-color: white;
]])

-- GUI.GaugeFrontCSS = CSSMan.new([[
--   background-color: rgba(0,0,0,0);
--   border-style: solid;
--   border-color: white;
--   border-width: 1px;
--   border-radius: 1px;
--   margin: 5px;
-- ]])

GUI.GaugeFrontCSS = CSSMan.new([[
  background-color: rgba(0,0,0,0);
  margin-top: 5px;
  margin-bottom: 5px;
  border-style: solid;
  border-color: white;S
]])



-- Function to create a new box
local function createBox(name, x, y, width, height, parent)
  local box = Geyser.Label:new({
    name = name,
    x = x,
    y = y,
    width = width,
    height = height,
  }, parent)
  box:setStyleSheet(GUI.BoxCSS:getCSS())
  return box
end



-- Create boxes using the reusable function
GUI.Box1 = createBox("GUI.Box1", 0, 0, "100%", "20%", GUI.Right)
GUI.Box2 = createBox("GUI.Box2", 0, "20%", "100%", "40%", GUI.Right)
GUI.Box3 = createBox("GUI.Box3", 0, "60%", "100%", "40%", GUI.Right)
GUI.Box4 = createBox("GUI.Box4", 0, 0, "100%", "50%", GUI.Left)
GUI.Box5 = createBox("GUI.Box5", 0, "50%", "100%", "25%", GUI.Left)
GUI.Box7 = createBox("GUI.Box7", 0, "75%", "100%", "25%", GUI.Left)


local Package_Root = getMudletHomeDir()



local Gui_Padding = 20

local function createContainer(name, parent)
  local container = Geyser.Container:new({
    name = name,
    x = 0,
    y = 0,
    width = "100%",
    height = "100%",
  }, parent)
  return container
end



GUI.Map_Container = createContainer("GUI.Map_Container", GUI.Box4)


GUI.Mapper = Geyser.Mapper:new({
  name = "GUI.Mapper",
  x = Gui_Padding,
  y = Gui_Padding,
  width = GUI.Map_Container:get_width() - (Gui_Padding * 2),
  height = GUI.Map_Container:get_height() - (Gui_Padding * 2),
}, GUI.Map_Container)



GUI.Room_Container = createContainer("GUI.Room_Container", GUI.Box5)


alui.roommini = Geyser.MiniConsole:new({
  name = "alui room miniconsole",
  x = Gui_Padding,
  y = Gui_Padding,
  width = GUI.Room_Container:get_width() - (Gui_Padding * 2),
  height = GUI.Room_Container:get_height() - (Gui_Padding * 2),
  color = "black",
  autoWrap = true,
}, GUI.Room_Container)



GUI.Status_Container = createContainer("GUI.Status_Container", GUI.Box7)

alui.combatmini = Geyser.MiniConsole:new({
  name = "alui combat console",
  x = Gui_Padding,
  y = Gui_Padding,
  height = GUI.Status_Container:get_height() - (Gui_Padding * 2),
  width = GUI.Status_Container:get_width() - (Gui_Padding * 2),
  color = "black",
  autoWrap = true,
}, GUI.Status_Container)







GUI.Style_Container = createContainer("GUI.Style_Container", GUI.Box1)



local Style_Colors = {
  Aim = { Hover = 'red', Up = 'red', Down = 'red' },
  Control = { Hover = 'green', Up = 'green', Down = 'green' },
  Offensive = { Hover = 'blue', Up = 'blue', Down = 'blue' },
  Dodge = { Hover = 'yellow', Up = 'yellow', Down = 'yellow' },
  Daring = { Hover = 'purple', Up = 'purple', Down = 'purple' },
  Parry = { Hover = 'orange', Up = 'orange', Down = 'orange' },
  Power = { Hover = 'green', Up = 'green', Down = 'green' },
  Speed = { Hover = 'red', Up = 'red', Down = 'red' },
  Attack = { Hover = 'blue', Up = 'blue', Down = 'blue' },
  Defense = { Hover = 'yellow', Up = 'yellow', Down = 'yellow' },
}


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







local Style_Button_Width = '10%'
local Style_Gauge_Width = "40%"


GUI.Style_Aim_Increase = Geyser.Button:new({
  name = "alui style aim increase",
  width = Style_Button_Width,
  tooltip = "Increase Aim Some",
  color = Style_Colors.Aim.Up,
  color_down = Style_Colors.Aim.Down,
  color_hover = Style_Colors.Aim.Hover,
}, GUI.Style_HBox_Aim_Control)
GUI.Style_Aim_Increase:echo("<center>Aim")

GUI.Style_Gauge_Aim_Control = Geyser.Gauge:new({
  name = "alui style gauge aim control",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Aim_Control)

GUI.Style_Control_Increase = Geyser.Button:new({
  name = "alui style control increase",
  width = Style_Button_Width,
  tooltip = "Increase Control Some",
  color = Style_Colors.Control.Up,
}, GUI.Style_HBox_Aim_Control)

GUI.Style_Control_Increase:echo("<center>Control")


GUI.Style_Gauge_Aim_Control:setValue(5, 10)

GUI.GaugeFrontCSS:set("background-color", Style_Colors.Control.Hover)

GUI.GaugeBackCSS:set("background-color", Style_Colors.Aim.Hover)
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
  tooltip = "Increase Offensive Some",
}, GUI.Style_HBox_Offensive_Dodge)
GUI.Style_Offensive_Increase:echo("<center>Offensive")

GUI.Style_Gauge_Offensive_Dodge = Geyser.Gauge:new({
  name = "alui style gauge offensive dodge",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Offensive_Dodge)

GUI.Style_Dodge_Increase = Geyser.Button:new({
  name = "alui style control dodge",
  width = Style_Button_Width,
  tooltip = "Increase Dodge Some",
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
  tooltip = "Increase Daring Some",
}, GUI.Style_HBox_Darring_Parry)

GUI.Style_Daring_Increase:echo("<center>Daring")

GUI.Style_Gauge_Daring_Parry = Geyser.Gauge:new({
  name = "alui style gauge daring parry",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Darring_Parry)

GUI.Style_Parry_Increase = Geyser.Button:new({
  name = "alui style parry increase",
  width = Style_Button_Width,
  tooltip = "Increase Parry Some",
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
  tooltip = "Increase Power Some",
}, GUI.Style_HBox_Power_Speed)

GUI.Style_Power_Increase:echo("<center>Power")

GUI.Style_Gauge_Power_Speed = Geyser.Gauge:new({
  name = "alui style gauge power speed",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Power_Speed)

GUI.Style_Speed_Increase = Geyser.Button:new({
  name = "alui style speed increase",
  width = Style_Button_Width,
  tooltip = "Increase Speed Some",
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
  tooltip = "Increase Attack Some",
}, GUI.Style_HBox_Attack_Defense)

GUI.Style_Attack_Increase:echo("<center>Attack")

GUI.Style_Gauge_Attack_Defense = Geyser.Gauge:new({
  name = "alui style gauge attack defense",
  width = Style_Gauge_Width,
}, GUI.Style_HBox_Attack_Defense)

GUI.Style_Defense_Increase = Geyser.Button:new({
  name = "alui style defense increase",
  width = Style_Button_Width,
  tooltip = "Increase Defense Some",
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
