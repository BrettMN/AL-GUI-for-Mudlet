local Package_Root = getMudletHomeDir()


GUI.Header = Geyser.HBox:new({
  name = "GUI.Header",
  x = 0,
  y = 0,
  width = "100%",
  height = "100%",
}, GUI.Top)

GUI.IconCSS = CSSMan.new([[
  background-color: rgba(0,0,0,100);
  border-style: solid;
  border-width: 1px;
  border-color: white;
  border-radius: 5px;
  margin: 5px;
  qproperty-wordWrap: true;
  background-repeat: no-repeat;
  background-position: top right; background-origin: margin;
]])

-- for i = 1, 12 do
--   GUI["Icon" .. i] = Geyser.Label:new({
--     name = "GUI.Icon" .. i,
--   }, GUI.Header)
--   GUI["Icon" .. i]:setStyleSheet(GUI.IconCSS:getCSS())
--   GUI["Icon" .. i]:echo("<center>GUI. Icon" .. i)
-- end

local function createMenuItem(name, parent)
  local item = Geyser.Label:new({
    name = 'GUI.Menu.' .. name,
  }, parent)

  item:setToolTip(name)
  item:setStyleSheet(GUI.IconCSS:getCSS())
  -- item:echo("<center>" .. name)
  return item
end

GUI.Menu.Hunger = createMenuItem("Hunger", GUI.Header)
GUI.Menu.Hunger:setBackgroundImage(Package_Root .. "/alui/icons/hungerIcon.png")
GUI.Menu.Hunger:setStyleSheet([[  background-color: red;
border-style: solid;
border-width: 1px;
border-color: white;
border-radius: 5px;
margin: 5px;
qproperty-wordWrap: true;
  background-repeat: no-repeat;
  background-position: top right; background-origin: margin;
]])
GUI.Menu.Thirst = createMenuItem("Thirst", GUI.Header)
GUI.Menu.Fatigue = createMenuItem("Fatigue", GUI.Header)
GUI.Menu.Posture = createMenuItem("Posture", GUI.Header)
GUI.Menu.Menu = createMenuItem("Menu", GUI.Header)
