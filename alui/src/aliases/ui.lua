local choice = matches[2] and string.lower(matches[2]) or nil

if choice == "on" or choice == "off" then
    ALUI.setUIEnabled(choice == "on")
    return
end

local enabled = not (ALUI and ALUI.uiDisabled)
cecho(("<cyan>ALUI interface is <white>%s<cyan>.\n"):format(enabled and "on" or "off"))
cecho("<white>  ui off  <dim_grey>- Turn the UI off and keep it off on every startup\n")
cecho("<white>  ui on   <dim_grey>- Turn the UI back on\n")
