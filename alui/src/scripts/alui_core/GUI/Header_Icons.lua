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
]])

-- for i = 1, 12 do
--   GUI["Icon" .. i] = Geyser.Label:new({
--     name = "GUI.Icon" .. i,
--   }, GUI.Header)
--   GUI["Icon" .. i]:setStyleSheet(GUI.IconCSS:getCSS())
--   GUI["Icon" .. i]:echo("<center>GUI. Icon" .. i)
-- end

local function createMenuItem(name, parent)
  local icon = Geyser.Label:new({
    name = 'GUI.Menu.' .. name,
  }, parent)
  icon:setStyleSheet(GUI.IconCSS:getCSS())
  icon:echo("<center>" .. name)
  return icon
end

GUI.Menu.Hunger = createMenuItem("Hunger", GUI.Header)
GUI.Menu.Thirst = createMenuItem("Thirst", GUI.Header)
GUI.Menu.Fatigue = createMenuItem("Fatigue", GUI.Header)
GUI.Menu.Posture = createMenuItem("Posture", GUI.Header)
GUI.Menu.Menu = createMenuItem("Menu", GUI.Header)
