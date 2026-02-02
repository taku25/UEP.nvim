-- lua/UEP/provider/build_targets.lua (RPC Optimized)
local unl_api = require("UNL.api")
local uep_log = require("UEP.logger").get()

local M = {}

function M.request(opts, on_complete)
  uep_log.debug("Provider 'uep.get_build_targets' called (RPC).")
  
  unl_api.db.get_target_files(function(rows, err)
      if err or not rows then
          if on_complete then on_complete(false, err) end
          return
      end
      
      local targets = {}
      for _, row in ipairs(rows) do
          local name = row.filename:gsub("%.Target%.cs$", "")
          local type = "Game"
          if name:match("Editor$") then type = "Editor"
          elseif name:match("Server$") then type = "Server"
          elseif name:match("Client$") then type = "Client" end

          table.insert(targets, { name = name, path = row.path, type = type })
      end
      if on_complete then on_complete(true, targets) end
  end)
end

return M