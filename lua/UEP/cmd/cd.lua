-- lua/UEP/cmd/cd.lua (修正版)

local projects_cache = require("UEP.cache.projects")
local unl_picker     = require("UNL.backend.picker")
local uep_log       = require("UEP.logger")
local uep_config    = require("UEP.config") -- ★★★ configをrequireする ★★★
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local M = {}

function M.execute(opts)
  local projects = projects_cache.load()
  
  if not next(projects) then
    uep_log.get().warn("No known projects found. Run :UEP refresh in a project first.", vim.log.levels.WARN)
    return
  end
  
  local picker_items = {}
  for root_path, meta in pairs(projects) do
    table.insert(picker_items, {
      label = string.format("%s (%s)", meta.name, root_path),
      value = root_path,
    })
  end
  
  unl_picker.pick({ -- ★ UNLPicker.pick("project", {..}) から pick({..}) に統一
    kind = "project", -- ★ kindをspecテーブル内に移動
    title = "Select Project to Change Directory",
    items = picker_items,
    conf = uep_config.get(), --- ★★★ この行を追加 ★★★
    
    format = function(item)
      return item.label
    end,
    
    on_submit = function(selected_root_path)
      if not selected_root_path then return end
      
      local ok, err = pcall(vim.api.nvim_set_current_dir, selected_root_path)
      unl_events.publish(unl_event_types.ON_AFTER_CHANGE_DIRECTORY, {
        status = ok and "success" or "failed",
        new_cwd = selected_root_path,
        error_message = err,
      })
      if ok then
        uep_log.get().info("Changed directory to: " .. selected_root_path, vim.log.levels.INFO)
      else
        uep_log.get().error("Failed to cd to '%s': %s", selected_root_path, tostring(err))
      end
    end,
    
    on_cancel = function()
      uep_log.get().info("Project CD cancelled by user.")
    end,
  })
end

return M
