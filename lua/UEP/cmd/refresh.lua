-- lua/UEP/cmd/refresh.lua (司令官・第三世代・最終完成版)

local unl_finder = require("UNL.finder")
local uep_config = require("UEP.config")
local unl_progress = require("UNL.backend.progress")
local uep_log = require("UEP.logger")
local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local files_cache_manager = require("UEP.cache.files")
local refresh_project_core = require("UEP.cmd.core.refresh_project")
local refresh_files_core = require("UEP.cmd.core.refresh_files")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")

local M = {}

function M.execute(opts, on_complete)
  opts = opts or {}
  local force_regenerate = opts.has_bang or false
  local log = uep_log.get()

  local project_info = unl_finder.project.find_project(vim.loop.cwd())
  if not (project_info and project_info.uproject) then
    if on_complete then on_complete(false) end
    return log.error("Could not find a .uproject file.")
  end
  local uproject_path = project_info.uproject
  local game_root = vim.fn.fnamemodify(uproject_path, ":h")
  
  local scope = opts.type
  if not scope then
    local project_display_name = vim.fn.fnamemodify(game_root, ":t")
    local registry_info = projects_cache.get_project_info(project_display_name)
    scope = registry_info and "Game" or "Full"
  end
  if force_regenerate then scope = "Full" end

  log.info("Starting refresh with scope: '%s', force: %s", scope, tostring(force_regenerate))

  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, { title = "UEP: Refreshing project...", client_name = "UEP" })
  progress:open()

  local function finish_all(ok)
    progress:finish(ok)
    unl_events.publish(unl_types.ON_AFTER_REFRESH_COMPLETED, { status = ok and "success" or "failed" })
    if on_complete then on_complete(ok) end
  end
  
  refresh_project_core.update_project_structure(scope, force_regenerate, uproject_path, progress, function(ok, result)
    if not ok then return finish_all(false) end
    
    local changed_components = result.changed_components
    local all_relevant_data = result.all_data
    local full_component_list = result.full_component_list

    -- ▼▼▼ 司令官の最後の、そして最も重要な仕事 ▼▼▼
    -- 分析結果を元に、マスターインデックスを更新する
    local engine_root = unl_finder.engine.find_engine_root(uproject_path, {})
    local registration_info = {
      root_path = game_root,
      uproject_path = uproject_path,
      engine_root = engine_root,
    }
    projects_cache.register_project_with_components(registration_info, full_component_list)
    -- ▲▲▲ ここまで ▲▲▲

    if #changed_components > 0 then
      refresh_files_core.create_component_caches_for(changed_components, all_relevant_data, game_root, engine_root, progress, function(files_ok)
        finish_all(files_ok)
      end)
    else
      log.info("All selected components are up-to-date. Nothing to refresh.")
      finish_all(true)
    end
  end)
end

return M
