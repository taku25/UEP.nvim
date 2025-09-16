-- lua/UEP/cmd/refresh.lua (司令官・修正版)

local unl_finder = require("UNL.finder")
local uep_config = require("UEP.config")
local unl_progress = require("UNL.backend.progress")
local uep_log = require("UEP.logger")
local projects_cache = require("UEP.cache.projects")
local refresh_project_core = require("UEP.cmd.core.refresh_project")
local refresh_files_core = require("UEP.cmd.core.refresh_files")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")

local M = {}

function M.execute(opts, on_complete)
  opts = opts or {}
  local log = uep_log.get()

  -- ▼▼▼ この部分が新しい引数解釈のロジックです ▼▼▼
  local refresh_opts = {
    bang = opts.has_bang or false,
    force = opts.force_flag == "--force",
    scope = opts.type, -- "Game", "Engine", or nil
  }
  -- ▲▲▲ ここまで ▲▲▲

  local project_info = unl_finder.project.find_project(vim.loop.cwd())
  if not (project_info and project_info.uproject) then
    if on_complete then on_complete(false) end
    return log.error("Could not find a .uproject file.")
  end
  local uproject_path = project_info.uproject
  local game_root = vim.fn.fnamemodify(uproject_path, ":h")

  if not refresh_opts.scope then
    local project_display_name = vim.fn.fnamemodify(game_root, ":t")
    local registry_info = projects_cache.get_project_info(project_display_name)
    refresh_opts.scope = registry_info and "Game" or "Full"
  end
  if refresh_opts.force then refresh_opts.scope = "Full" end -- --forceは常にFullスコープ

  log.info("Starting refresh with scope: '%s', bang: %s, force: %s",
    refresh_opts.scope, tostring(refresh_opts.bang), tostring(refresh_opts.force))


  local progress_weights = {
    parse_components = 0.7,
    -- resolve_deps = 0.05,
    -- save_components = 0.095,
    file_scan = 0.05,
    header_analysis = 0.2,
    cache_save = 0.05,
  }


  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, {
    title = "UEP: Refreshing project...",
    client_name = "UEP",
    weights = progress_weights;
  })
  progress:open()

  local function finish_all(ok)
    progress:finish(ok)
    unl_events.publish(unl_types.ON_AFTER_REFRESH_COMPLETED, { status = ok and "success" or "failed" })
    if on_complete then on_complete(ok) end
  end

  -- ▼▼▼ ここが正しい4引数の呼び出しです ▼▼▼
  refresh_project_core.update_project_structure(refresh_opts, uproject_path, progress, function(ok, result)
    if not ok then return finish_all(false) end

    local changed_components = result.changed_components
    local all_relevant_data = result.all_data
    local full_component_list = result.full_component_list

    local engine_root = unl_finder.engine.find_engine_root(uproject_path, {})
    local registration_info = {
      root_path = game_root,
      uproject_path = uproject_path,
      engine_root = engine_root,
    }
    projects_cache.register_project_with_components(registration_info, full_component_list)

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
