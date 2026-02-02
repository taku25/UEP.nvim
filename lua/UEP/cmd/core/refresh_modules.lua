-- lua/UEP/cmd/core/refresh_modules.lua (RPC Optimized)
local unl_api = require("UNL.api")
local uep_log = require("UEP.logger")

local M = {}

---
-- モジュール全体の更新 (Gameスコープリフレッシュを実行)
function M.update_single_module_cache(module_name, on_complete)
  local log = uep_log.get()
  log.info("Refreshing module: %s (via RPC refresh)", module_name)
  unl_api.refresh({ scope = "Game" }, on_complete)
end

---
-- 単一ファイルの更新 (RPC Scan呼び出し)
function M.update_single_file_cache(module_name, file_path, on_complete)
  local log = uep_log.get()
  
  unl_api.db.get_module_id_by_name(module_name, function(module_id, err)
      if err or not module_id then
          log.warn("Module ID not found for '%s', skipping auto-refresh for: %s", module_name, file_path)
          if on_complete then on_complete(false) end
          return
      end

      local mtime = vim.fn.getftime(file_path)
      if mtime == -1 then mtime = 0 end

      -- Note: scanner.run_async via stdin is still valid as main.rs proxies it
      -- but we can use direct RPC in the future.
      local payload = {
          type = "scan",
          files = {
              {
                  path = file_path:gsub("\\", "/"),
                  mtime = math.floor(mtime),
                  module_id = math.floor(module_id),
                  -- db_path is now implicit on server, but CLI scan mode might still need it 
                  -- if called via unl-scanner. server handle_scan uses it from first file.
              }
          }
      }

      unl_api.scanner.run_async(payload, nil, function(success)
          if success then
              log.info("Auto-refresh completed for: %s", vim.fn.fnamemodify(file_path, ":t"))
              if on_complete then on_complete(true) end
          else
              log.error("Auto-refresh failed for: %s", file_path)
              if on_complete then on_complete(false) end
          end
      end)
  end)
end

return M
