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
    background-position: center;
]])


local function createMenuItem(name, iconPath, label, backgroundColor, statusProperty, parent)
  local item = Geyser.Label:new({
    name = 'GUI.Menu.' .. name,
  }, parent)

  item.settings = {
    name = name,
    iconPath = iconPath,
    label = label,
    backgroundColor = backgroundColor,
    statusProperty = statusProperty
  }

  item.update = function(self)
    local settings = self.settings
    local iconPath = settings.iconPath
    local label = settings.label
    local backgroundColor = settings.backgroundColor or 'none'
    local statusProperty = settings.statusProperty

    if statusProperty then
      backgroundColor = alui.status[statusProperty] or backgroundColor
    end

    if iconPath then
      GUI.IconCSS:set("background-image", iconPath)
    else
      GUI.IconCSS:set("background-image", "none")
      if label then
        item:echo("<center>" .. label)
      end
    end
    if backgroundColor then
      GUI.IconCSS:set("background-color", backgroundColor)
    else
      GUI.IconCSS:set("background-color", "rgba(0,0,0,100)")
    end

    item:setStyleSheet(GUI.IconCSS:getCSS())
  end

  item:update()

  return item
end






GUI.Menu.Hunger = createMenuItem("Hunger", "url(" .. Package_Root .. "/alui/icons/hungerIcon.png)", nil,
  alui.status.hunger, 'hunger',
  GUI.Header)
GUI.Menu.Thirst = createMenuItem("Thirst", "url(" .. Package_Root .. "/alui/icons/thirstIcon.png)", nil,
  alui.status.thirst, 'thirst',
  GUI.Header)
GUI.Menu.Fatigue = createMenuItem("Fatigue", "url(" .. Package_Root .. "/alui/icons/fatigueIcon.png)", nil,
  alui.status.fatigue, 'fatigue', GUI.Header)
GUI.Menu.Posture = createMenuItem("Posture", "url(" .. Package_Root .. "/alui/icons/postureIcon.png)", alui.status
  .posture, nil, 'posture', GUI.Header)
GUI.Menu.Menu = createMenuItem("Menu", "url(" .. Package_Root .. "/alui/icons/menuIcon.png)", nil, nil, nil, GUI.Header)
