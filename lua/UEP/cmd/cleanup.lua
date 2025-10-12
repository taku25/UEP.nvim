-- lua/UEP/cmd/cleanup.lua (新規作成)

local core_utils = require("UEP.cmd.core.utils")
local project_cache = require("UEP.cache.project")
local files_cache_manager = require("UEP.cache.files")
local projects_cache = require("UEP.cache.projects")
local uep_log = require("UEP.logger")
local unl_progress = require("UNL.backend.progress")
local uep_config = require("UEP.config")

local M = {}

---
-- プロジェクトの全コンポーネントのキャッシュを削除するコアロジック
-- @param maps table core_utils.get_project_mapsの結果
local function execute_project_cleanup(maps)
  local log = uep_log.get()
  local project_display_name = vim.fn.fnamemodify(maps.project_root, ":t")
  
  -- 1. ユーザーへの最終確認（vim.fn.confirmは同期処理）
  local prompt_str = ("Permanently delete ALL structural and file cache files for project '%s'? (Run :UEP refresh afterwards)"):format(project_display_name)
  local choices = "&Yes\n&No"
  local decision = vim.fn.confirm(prompt_str, choices, 2)

  if decision ~= 1 then
    return log.info("Project cleanup cancelled by user.")
  end
  
  -- Yesが選択された (decision == 1) 場合の処理
  
  local components_to_clean = maps.full_component_list or vim.tbl_values(maps.all_components_map)
  local total_tasks = #components_to_clean * 2 -- 各コンポーネントにつき、構造キャッシュとファイルキャッシュの2タスク
  local deleted_count = 0

  -- 2. プログレスバーの初期化
  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, {
    title = ("UEP: Cleaning up %s..."):format(project_display_name),
    client_name = "UEP.Cleanup",
    weights = { cleanup_tasks = 1.0 } -- Cleanup専用の単一ステージ
  })
  progress:open()

  local current_task_count = 0
  local function update_progress(display_name, type)
    current_task_count = current_task_count + 1
    local msg = ("Deleting %s cache for %s... [%d/%d]"):format(type, display_name, current_task_count, total_tasks)
    progress:stage_define("cleanup_tasks", total_tasks) -- 毎回定義し直すのは非効率だが、ここでは確実性を優先
    progress:stage_update("cleanup_tasks", current_task_count, msg)
  end

  local function run_cleanup_async()
    for _, component in ipairs(components_to_clean) do
      local comp_name = component.name
      local display_name = component.display_name

      -- A. ファイルキャッシュ (*.files.json) を削除
      update_progress(display_name, "File")
      if files_cache_manager.delete_component_cache_file(component) then
        deleted_count = deleted_count + 1
      end
      
      -- B. プロジェクト構造キャッシュ (*.project.json) を削除
      local project_cache_filename = comp_name .. ".project.json"
      update_progress(display_name, "Project Structural")
      local ok_proj = project_cache.delete_component_cache_file(project_cache_filename)
      if ok_proj then
        deleted_count = deleted_count + 1
      end
    end
    
    -- 3. 終了処理
    progress:finish(true)
    log.info("Cleanup completed for project '%s'. %d cache files were cleared. Please run :UEP refresh.", project_display_name, deleted_count)
    vim.notify(string.format("Cleanup complete. Run :UEP refresh to rebuild caches."), vim.log.levels.INFO)
  end

  -- 3. メインの処理を遅延実行し、UIスレッドをブロックしないようにする
  vim.defer_fn(run_cleanup_async, 10)
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 1. プロジェクトルートを取得し、レジストリ情報を確認
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then 
      -- プロジェクトがレジストリに見つからない場合でも、プロジェクトルートだけは探す
      local project_root = require("UNL.finder").project.find_project_root(vim.loop.cwd())
      if project_root then
        -- レジストリがない場合でも、キャッシュは存在する可能性があるので続行（ただし、全コンポーネントリストの取得は困難）
        -- この場合は、まずリフレッシュを促すのがより安全
        return log.warn("Project not fully registered. Please run :UEP refresh first.")
      else
        return log.error("Not in an Unreal Engine project directory.")
      end
    end
    
    -- 2. コアロジックを実行
    execute_project_cleanup(maps)
  end)
end

return M
