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

local Style_Button_Width = '10%'
local Style_Gauge_Width = "40%"
local Package_Root = getMudletHomeDir()
local Gui_Padding = 20

local Style_Colors = {
  Aim = { Hover = 'red', Up = 'red', Pressed = 'red' },
  Control = { Hover = 'green', Up = 'green', Pressed = 'green' },
  Offensive = { Hover = 'blue', Up = 'blue', Pressed = 'blue' },
  Dodge = { Hover = 'yellow', Up = 'SaddleBrown', Pressed = 'yellow' },
  Daring = { Hover = 'purple', Up = 'purple', Pressed = 'purple' },
  Parry = { Hover = 'orange', Up = 'DarkOrange', Pressed = 'orange' },
  Power = { Hover = 'green', Up = 'SlateGrey', Pressed = 'green' },
  Speed = { Hover = 'red', Up = 'MidnightBlue', Pressed = 'red' },
  Attack = { Hover = 'blue', Up = 'DarkGreen', Pressed = 'blue' },
  Defense = { Hover = 'yellow', Up = 'DarkViolet', Pressed = 'yellow' },
}






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


local function createStyleHbox(name, parent)
  local Style_HBox_Height = "20%"
  local hbox = Geyser.HBox:new({
    name = name,
    width = "100%",
    height = Style_HBox_Height,
  }, parent)
  return hbox
end


local function createStyleButton(name, parent, color)
  local button = Geyser.Button:new({
    name = "GUI.Style_" .. name .. "_Increase",
    width = Style_Button_Width,
    tooltip = 'Increase ' .. name .. ' Some',

    style = [[ margin: 5px; boarder-radius:5px; background-color: ]] .. color.Up .. [[; border: 1px solid white; ]],
    downStyle = [[ margin: 1px; background-color: ]] .. color.Pressed .. [[; border: 1px solid white; ]],
  }, parent)
  button:echo("<center>" .. name)

  button:setClickCallback(function()
    send('increase ' .. string.lower(name) .. ' some', false)
  end)
  return button
end

local function createStyleGauge(name, parent, leftColor, rightColor)
  local gauge = Geyser.Gauge:new({
    name = "GUI.Style_Gauge_" .. name,
    width = Style_Gauge_Width,
  }, parent)
  gauge:setValue(5, 10)
  GUI.GaugeFrontCSS:set("background-color", leftColor.Up)
  GUI.GaugeBackCSS:set("background-color", rightColor.Up)
  gauge.back:setStyleSheet(GUI.GaugeBackCSS:getCSS())
  gauge.front:setStyleSheet(GUI.GaugeFrontCSS:getCSS())
  return gauge
end


-- Create boxes using the reusable function
GUI.Box1 = createBox("GUI.Box1", 0, 0, "100%", "20%", GUI.Right)
GUI.Box2 = createBox("GUI.Box2", 0, "20%", "100%", "40%", GUI.Right)
GUI.Box3 = createBox("GUI.Box3", 0, "60%", "100%", "40%", GUI.Right)
GUI.Box4 = createBox("GUI.Box4", 0, 0, "100%", "50%", GUI.Left)
GUI.Box5 = createBox("GUI.Box5", 0, "50%", "100%", "25%", GUI.Left)
GUI.Box7 = createBox("GUI.Box7", 0, "75%", "100%", "25%", GUI.Left)

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




GUI.Style_VBox = Geyser.VBox:new({
  name = "alui style vbox",
  x = Gui_Padding,
  y = Gui_Padding,
  width = GUI.Style_Container:get_width() - (Gui_Padding * 2),
  height = GUI.Style_Container:get_height() - (Gui_Padding * 2),
}, GUI.Style_Container)








GUI.Style_HBox_Aim_Control = createStyleHbox("GUI.Style_HBox_Aim_Control", GUI.Style_VBox)
GUI.Style_HBox_Offensive_Dodge = createStyleHbox("GUI.Style_HBox_Offensive_Dodge", GUI.Style_VBox)
GUI.Style_HBox_Darring_Parry = createStyleHbox("GUI.Style_HBox_Darring_Parry", GUI.Style_VBox)
GUI.Style_HBox_Power_Speed = createStyleHbox("GUI.Style_HBox_Power_Speed", GUI.Style_VBox)
GUI.Style_HBox_Attack_Defense = createStyleHbox("GUI.Style_HBox_Attack_Defense", GUI.Style_VBox)






GUI.Style_Aim_Increase = createStyleButton("Aim", GUI.Style_HBox_Aim_Control, Style_Colors.Aim)
GUI.Style_Gauge_Aim_Control = createStyleGauge("GUI.Style_Gauge_Aim_Control", GUI.Style_HBox_Aim_Control,
  Style_Colors.Control, Style_Colors.Aim)
GUI.Style_Control_Increase = createStyleButton("Control", GUI.Style_HBox_Aim_Control, Style_Colors.Control)


GUI.Style_Offensive_Increase = createStyleButton("Offensive", GUI.Style_HBox_Offensive_Dodge, Style_Colors.Offensive)
GUI.Style_Gauge_Offensive_Dodge = createStyleGauge("Offensive_Dodge", GUI.Style_HBox_Offensive_Dodge, Style_Colors.Dodge,
  Style_Colors.Offensive)
GUI.Style_Dodge_Increase = createStyleButton("Dodge", GUI.Style_HBox_Offensive_Dodge, Style_Colors.Dodge)



GUI.Style_Daring_Increase = createStyleButton("Daring", GUI.Style_HBox_Darring_Parry, Style_Colors.Daring)
GUI.Style_Gauge_Daring_Parry = createStyleGauge("Daring_Parry", GUI.Style_HBox_Darring_Parry, Style_Colors.Parry,
  Style_Colors.Daring)
GUI.Style_Parry_Increase = createStyleButton("Parry", GUI.Style_HBox_Darring_Parry, Style_Colors.Parry)


GUI.Style_Power_Increase = createStyleButton("Power", GUI.Style_HBox_Power_Speed, Style_Colors.Power)
GUI.Style_Gauge_Power_Speed = createStyleGauge("Power_Speed", GUI.Style_HBox_Power_Speed, Style_Colors.Speed,
  Style_Colors.Power)
GUI.Style_Speed_Increase = createStyleButton("Speed", GUI.Style_HBox_Power_Speed, Style_Colors.Speed)



GUI.Style_Attack_Increase = createStyleButton("Attack", GUI.Style_HBox_Attack_Defense, Style_Colors.Attack)
GUI.Style_Gauge_Attack_Defense = createStyleGauge("Attack_Defense", GUI.Style_HBox_Attack_Defense, Style_Colors.Defense,
  Style_Colors.Attack)
GUI.Style_Defense_Increase = createStyleButton("Defense", GUI.Style_HBox_Attack_Defense, Style_Colors.Defense)













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
