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
  
  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, { title = "UEP: Refreshing project...", client_name = "UEP" })
  progress:open()

  local function finish_all(ok)
    progress:finish(ok)
    unl_events.publish(unl_types.ON_AFTER_REFRESH_COMPLETED, { status = ok and "success" or "failed" })
    if on_complete then on_complete(ok) end
  end
  
  -- STEP 1: プロジェクトの完全なコンポーネントリストを取得
  refresh_project_core.get_full_component_list(uproject_path, progress, function(ok, all_components)
    if not ok then return finish_all(false) end

    -- STEP 2: 各コンポーネントが最新かどうかを判定
    local components_to_refresh = {}
    local up_to_date_components_data = {}
    
    for _, component in ipairs(all_components) do
      local proj_cache_path = component.name .. ".project.json"
      local project_cache_data = project_cache.load(proj_cache_path)
      local file_cache_data = files_cache_manager.load_component_cache(component)

      local needs_refresh = force_regenerate 
                           or not project_cache_data 
                           or not file_cache_data

      if needs_refresh then
        table.insert(components_to_refresh, component)
      else
        up_to_date_components_data[component.name] = project_cache_data
      end
    end

    if #components_to_refresh == 0 then
      log.info("Project is already up-to-date.")
      return finish_all(true)
    end

    -- STEP 3: "要修復"コンポーネントだけの分析を命令
    refresh_project_core.analyze_selected_components(components_to_refresh, up_to_date_components_data, progress, function(analysis_ok, refreshed_data)
      if not analysis_ok then return finish_all(false) end
      
      -- STEP 4: "要修復"コンポーネントだけのファイルスキャンを命令
      local final_data_for_files = vim.tbl_deep_extend("force", {}, up_to_date_components_data, refreshed_data)
      refresh_files_core.create_component_caches_for(components_to_refresh, final_data_for_files, progress, function(files_ok)
        finish_all(files_ok)
      end)
    end)
  end)
end

return M
