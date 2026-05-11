local function getBaseDir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    local path = source:sub(2):gsub("\\", "/")
    return path:match("^(.*)/[^/]+$")
  end

  return getMudletHomeDir():gsub("\\", "/") .. "/alui"
end

local function loadVendoredModule(relativePath, moduleName)
  local chunk, err = loadfile(getBaseDir() .. "/" .. relativePath)
  assert(chunk, err)
  return chunk(moduleName)
end

return loadVendoredModule("demonnic-MDK-2.10.0/loggingconsole.lua", ... or "alui.loggingconsole")
