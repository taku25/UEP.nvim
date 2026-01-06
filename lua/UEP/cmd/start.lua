-- lua/UEP/cmd/start.lua
local uep_log = require("UEP.logger")
local uep_watcher = require("UEP.watcher")
local uep_db = require("UEP.db.init")
local cmd_refresh = require("UEP.cmd.refresh")

local M = {}

M.run = function(opts)
  if uep_watcher.is_running() then
    uep_log.get().warn("UEP watcher is already running.")
    return
  end
  
  -- DBファイルがあるか確認
  local db_path = uep_db.get_path()
  local db_exists = (vim.fn.filereadable(db_path) == 1)

  if db_exists then
    uep_watcher.start()
  else
    uep_log.get().info("UEP database not found. Starting initial refresh (Full)...")
    
    -- 初回リフレッシュを実行
    cmd_refresh.execute({ scope = "Full" }, function(success)
      if success then
        uep_log.get().info("Initial refresh completed. Starting watcher...")
        uep_watcher.start()
      else
        uep_log.get().error("Initial refresh failed. Watcher NOT started.")
      end
    end)
  end
end

return M
