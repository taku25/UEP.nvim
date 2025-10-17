-- lua/UEP/cmd/refresh.lua (司令官・修正版)

local unl_finder = require("UNL.finder")
local uep_config = require("UEP.config")
local unl_progress = require("UNL.backend.progress")
local uep_log = require("UEP.logger")
local projects_cache = require("UEP.cache.projects")
local files_cache_manager = require("UEP.cache.files")
local refresh_project_core = require("UEP.cmd.core.refresh_project")
local refresh_files_core = require("UEP.cmd.core.refresh_files")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")

local M = {}

function M.execute(opts, on_complete)
  opts = opts or {}
  local log = uep_log.get()

  local refresh_opts = {
    bang = opts.has_bang or false,
    force = opts.force_flag == "--force",
    scope = opts.type, -- "Game", "Engine", or nil
  }

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


  refresh_project_core.update_project_structure(refresh_opts, uproject_path, progress, function(ok, result)
  if not ok then return finish_all(false) end

    -- STEP 1: プロジェクト構造の更新結果を取得
    local changed_components = result.changed_components
    local all_components_data = result.all_data
    local full_component_list = result.full_component_list

    -- STEP 2: マスターインデックスを更新 (これは常に実行)
    local engine_root = unl_finder.engine.find_engine_root(uproject_path,
      {
        engine_override_path = uep_config.get().engine_path,
      })
    local registration_info = {
      root_path = game_root,
      uproject_path = uproject_path,
      engine_root = engine_root,
    }

    projects_cache.register_project_with_components(registration_info, full_component_list)

    -- STEP 3: ファイルスキャン対象のコンポーネントを決定する
    local components_to_scan = {}

    if refresh_opts.bang or refresh_opts.force then
      -- ケースA: bang(!) または --force が指定された場合、スコープ内の全コンポーネントをスキャン対象とする
      log.info("Bang(!) or --force specified. All components in scope will be scanned for files.")
      
      if refresh_opts.scope == "Full" then
        components_to_scan = full_component_list
      else -- Game または Engine
        local game_name = files_cache_manager.get_name_from_root(game_root)
        local eng_name = files_cache_manager.get_name_from_root(engine_root)
        local owner_name_to_match = (refresh_opts.scope == "Engine" and eng_name) or game_name
        
        for _, comp in ipairs(full_component_list) do
            if comp.owner_name == owner_name_to_match then
                table.insert(components_to_scan, comp)
            end
        end
      end
    else
      -- ケースB: 通常の refresh の場合
      local components_added = {}
      local function add_to_scan_list(component)
          if not components_added[component.name] then
              table.insert(components_to_scan, component)
              components_added[component.name] = true
          end
      end
      
      -- B-1: 構造が変更されたコンポーネントを追加
      for _, c in ipairs(changed_components) do add_to_scan_list(c) end

      -- B-2: ファイルキャッシュが存在しないコンポーネントを追加
      for _, component in ipairs(full_component_list) do
        if not components_added[component.name] then
          if not files_cache_manager.load_component_cache(component) then
            log.info("File cache for component '%s' not found. Adding to scan queue.", component.display_name)
            add_to_scan_list(component)
          end
        end
      end
    end

    -- STEP 4: 決定した対象リストに基づいてファイルスキャンを実行
    if #components_to_scan > 0 then
      log.info("Starting file scan for %d component(s).", #components_to_scan)
      refresh_files_core.create_component_caches_for(components_to_scan, all_components_data, game_root, engine_root, progress, function(files_ok)
        finish_all(files_ok)
      end)
    else
      log.info("Project structure is up-to-date and all file caches exist. Nothing to refresh.")
      finish_all(true)
    end
  end)
end

return M
