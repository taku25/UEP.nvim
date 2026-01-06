-- lua/UEP/cmd/stop.lua
local uep_log = require("UEP.logger")
local uep_watcher = require("UEP.watcher")

local M = {}

M.run = function(opts)
  if not uep_watcher.is_running() then
    uep_log.get().warn("UEP watcher is not running.")
    return
  end
  
  uep_watcher.stop()
end

return M
