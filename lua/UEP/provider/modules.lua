-- lua/UEP/provider/modules.lua (新規作成)

local core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger").get()

local M = {}

-- unl_providerから呼び出されるメイン関数
function M.request(opts)
  opts = opts or {}
  uep_log.debug("Provider 'uep.get_project_modules' was called.")

  local modules = nil
  local error_msg = nil

  -- get_project_mapsは非同期コールバック形式だが、処理自体は同期的。
  -- これをラップして同期的な戻り値に変換する。
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      error_msg = tostring(maps)
      return
    end

    local all_modules_map = maps.all_modules_map
    local picker_items = {}
    for name, meta in pairs(all_modules_map) do
      table.insert(picker_items, {
        name = name,
        category = meta.category,
        location = meta.location,
        root_path = meta.module_root,
      })
    end
    table.sort(picker_items, function(a, b) return a.name < b.name end)
    modules = picker_items
  end)

  if error_msg then
    uep_log.error("Provider 'uep.get_project_modules' failed: %s", error_msg)
    return nil
  end

  uep_log.info("Provider 'uep.get_project_modules' succeeded, returning %d modules.", #modules)
  return modules
end

return M
