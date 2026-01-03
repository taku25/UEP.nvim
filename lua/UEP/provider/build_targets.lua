-- lua/UEP/provider/build_targets.lua
-- UBT.nvim などの外部プラグインに、検出済みのビルドターゲットを提供する

local uep_db = require("UEP.db.init")
local uep_log = require("UEP.logger").get()

local M = {}

---
-- UNL.api.provider.request("uep.get_build_targets") から呼び出される
function M.request(opts)
  uep_log.debug("Provider 'uep.get_build_targets' was called (DB).")
  
  local db = uep_db.get()
  if not db then return nil end
  
  local rows = db:eval("SELECT path, filename FROM files WHERE filename LIKE '%.Target.cs'")
  if not rows then return {} end
  
  local targets = {}
  for _, row in ipairs(rows) do
      local name = row.filename:gsub("%.Target%.cs$", "")
      
      -- Determine target type (Editor or Game/Program)
      local type = "Game" -- Default
      if name:match("Editor$") then
          type = "Editor"
      elseif name:match("Server$") then
          type = "Server"
      elseif name:match("Client$") then
          type = "Client"
      end

      table.insert(targets, {
          name = name,
          path = row.path,
          type = type
      })
  end
  uep_log.info("Provider 'uep.get_build_targets' succeeded, returning %d targets.", #targets)
  return targets
end

return M
