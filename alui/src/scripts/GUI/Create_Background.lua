

GUI.BackgroundCSS = CSSMan.new([[
  background-color: rgb(20,0,20);
  background-image: url('C:\workspace\AL-GUI-for-Mudlet\alui\src\resources\banner.webp');
]])

GUI.Left = Geyser.Label:new({
  name = "GUI.Left",
  x = 0, y = 0,
  width = "25%",
  height = "100%",
})
GUI.Left:setStyleSheet(GUI.BackgroundCSS:getCSS())

GUI.Right = Geyser.Label:new({
  name = "GUI.Right",
  x = "-25%", y = 0,
  width = "25%",
  height = "100%",
  backgroundImages = "url('/banner.webp')",
})
GUI.Right:setStyleSheet(GUI.BackgroundCSS:getCSS())

GUI.Top = Geyser.Label:new({
  name = "GUI.Top",
  x = "25%", y = 0,
  width = "50%",
  height = "10%",
})
GUI.Top:setStyleSheet(GUI.BackgroundCSS:getCSS())

GUI.Bottom = Geyser.Label:new({
  name = "GUI.Bottom",
  x = "25%", y = "90%",
  width = "50%",
  height = "10%",
})
GUI.Bottom:setStyleSheet(GUI.BackgroundCSS:getCSS())