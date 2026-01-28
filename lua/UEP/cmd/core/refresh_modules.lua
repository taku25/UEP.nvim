-- lua/UEP/cmd/core/refresh_modules.lua (Rust Scanner Wrapper)
local uep_db = require("UEP.db.init")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")

local M = {}

---
-- モジュール全体の更新 (Gameスコープリフレッシュを実行)
function M.update_single_module_cache(module_name, on_complete)
  local log = uep_log.get()
  log.info("Refreshing module: %s (via Game refresh)", module_name)
  
  -- 現状は Game スコープのリフレッシュを実行するのが最も安全で速い
  require("UEP.cmd.refresh").execute({ scope = "Game" }, on_complete)
end

---
-- 単一ファイルの更新 (Rust スキャナの Scan モードを呼び出し)
function M.update_single_file_cache(module_name, file_path, on_complete)
  local log = uep_log.get()
  local unl_scanner = require("UNL.scanner")
  local db_path = uep_db.get_path()
  
  -- DBからmodule_idを取得
  local db = uep_db.get()
  if not db then 
    if on_complete then on_complete(false) end
    return 
  end
  
  local rows = db:eval("SELECT id FROM modules WHERE name = ? LIMIT 1", { module_name })
  local module_id = (type(rows) == "table" and rows[1]) and rows[1].id or nil

  if not module_id then
      log.warn("Module ID not found for '%s', skipping auto-refresh for: %s", module_name, file_path)
      if on_complete then on_complete(false) end
      return
  end

  local mtime = vim.fn.getftime(file_path)
  if mtime == -1 then mtime = 0 end

  local payload = {
      type = "scan",
      files = {
          {
              path = file_path:gsub("\\", "/"),
              mtime = math.floor(mtime),
              module_id = math.floor(module_id),
              db_path = db_path:gsub("\\", "/"),
          }
      }
  }

  log.debug("Auto-refreshing file via Rust scanner: %s", file_path)
  unl_scanner.run_async(payload, nil, function(success)
      if success then
          log.info("Auto-refresh completed for: %s", vim.fn.fnamemodify(file_path, ":t"))
          if on_complete then on_complete(true) end
      else
          log.error("Auto-refresh failed for: %s", file_path)
          if on_complete then on_complete(false) end
      end
  end)
end

return M