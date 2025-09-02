local projects_cache = require("UEP.cache.projects")
local unl_picker     = require("UNL.backend.picker")
local uep_log        = require("UEP.logger")
local uep_config     = require("UEP.config")
-- ★★★ イベント関連のモジュールをrequire ★★★
local unl_events     = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")

local M = {}

-------------------------------------------------
-- Core Logic
-------------------------------------------------

local function execute_project_deletion(project_root)
  local project_name = projects_cache.load()[project_root].name or project_root
  local prompt_str = ("Permanently remove '%s' from the project registry?"):format(project_name)

  vim.ui.select(
    { "Yes, remove from registry", "No, cancel" },
    { prompt = prompt_str },
    function(choice)
      if not choice or choice ~= "Yes, remove from registry" then
        uep_log.get().info("Project registry deletion cancelled.")
        return vim.notify("Deletion cancelled.", vim.log.levels.INFO)
      end
      
      -- 削除処理を実行し、成功したかチェック
      local ok = projects_cache.remove(project_root)

      -- ★★★ 結果に基づいてイベントを発行 ★★★
      unl_events.publish(unl_event_types.ON_AFTER_DELETE_PROJECT_REGISTRY, {
        status = ok and "success" or "failed",
        project_root = project_root,
      })

      if ok then
        uep_log.get().info("Project removed from registry: %s", project_root)
      else
        uep_log.get().error("Failed to remove project from registry: %s", project_root)
      end
    end
  )
end

-------------------------------------------------
-- Public API (UI Flow)
-------------------------------------------------
function M.execute(opts)
  local projects = projects_cache.load()
  if not projects or not next(projects) then
    return uep_log.get().warn("No known projects to delete.", vim.log.levels.WARN)
  end
  
  local picker_items = {}
  for root_path, meta in pairs(projects) do
    table.insert(picker_items, {
      label = string.format("%s (%s)", meta.name, root_path),
      value = root_path,
    })
  end
  table.sort(picker_items, function(a, b) return a.label < b.label end)
  
  unl_picker.pick({
    kind = "project_delete",
    title = "Select Project to DELETE from registry",
    items = picker_items,
    conf = uep_config.get(),
    on_submit = function(selected_root_path)
      if not selected_root_path then
        return
      end
      execute_project_deletion(selected_root_path)
    end,
  })
end

return M
