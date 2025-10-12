-- lua/UEP/cmd/delete.lua (修正版)

local projects_cache = require("UEP.cache.projects")
local unl_picker     = require("UNL.backend.picker")
local uep_log        = require("UEP.logger")
local uep_config     = require("UEP.config")
local unl_events     = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")

local M = {}

-------------------------------------------------
-- Core Logic
-------------------------------------------------
-- ▼▼▼ 修正点: 引数をproject_rootからproject_display_nameに変更 ▼▼▼
local function execute_project_deletion(project_display_name)
  local prompt_str = ("Permanently remove '%s' from the project registry?"):format(project_display_name)

  vim.ui.select(
    { "Yes, remove from registry", "No, cancel" },
    { prompt = prompt_str },
    function(choice)
      if not choice or choice ~= "Yes, remove from registry" then
        uep_log.get().info("Project registry deletion cancelled.")
        return vim.notify("Deletion cancelled.", vim.log.levels.INFO)
      end
      
      -- ▼▼▼ 修正点: 正しい引数で削除関数を呼び出す ▼▼▼
      local ok = projects_cache.remove_project(project_display_name)
      -- ▲▲▲ ここまで ▲▲▲

      unl_events.publish(unl_event_types.ON_AFTER_DELETE_PROJECT_REGISTRY, {
        status = ok and "success" or "failed",
        project_display_name = project_display_name,
      })

      if ok then
        uep_log.get().info("Project removed from registry: %s", project_display_name)
      else
        uep_log.get().error("Failed to remove project from registry: %s", project_display_name)
      end
    end
  )
end
-- ▲▲▲ ここまで ▲▲▲

-------------------------------------------------
-- Public API (UI Flow)
-------------------------------------------------
function M.execute(opts)
  -- ▼▼▼ 修正点: cdコマンドと同様に、projectsテーブルを正しく取得 ▼▼▼
  local registry = projects_cache.load()
  local projects = registry.projects
  -- ▲▲▲ ここまで ▲▲▲

  if not projects or not next(projects) then
    return uep_log.get().warn("No known projects to delete.", vim.log.levels.WARN)
  end
  
  local picker_items = {}
  -- ▼▼▼ 修正点: 新しいデータ構造に合わせてループ処理を修正 ▼▼▼
  for display_name, meta in pairs(projects) do
    local root_path = vim.fn.fnamemodify(meta.uproject_path, ":h")
    table.insert(picker_items, {
      label = string.format("%s (%s)", display_name, root_path),
      value = display_name, -- ★ピッカーが返す値は、削除に必要な「表示名」にする
    })
  end
  -- ▲▲▲ ここまで ▲▲▲
  table.sort(picker_items, function(a, b) return a.label < b.label end)
  
  unl_picker.pick({
    kind = "project_delete",
    title = "Select Project to DELETE from registry",
    items = picker_items,
    conf = uep_config.get(),
    preview_enabled = false,
    on_submit = function(selected_display_name) -- ★受け取る値は表示名
      if not selected_display_name then
        return
      end
      execute_project_deletion(selected_display_name)
    end,
  })
end

return M
