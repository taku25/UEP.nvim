-- From: lua\UEP\cmd\cleanup.lua
-- lua/UEP/cmd/cleanup.lua (モジュールキャッシュ・レジストリ削除対応 最終版)

local core_utils = require("UEP.cmd.core.utils")
local projects_cache = require("UEP.cache.projects")
local uep_db = require("UEP.db.init") -- [!] DB追加
local uep_log = require("UEP.logger")
local unl_progress = require("UNL.backend.progress")
local uep_config = require("UEP.config")
local fs = require("vim.fs") -- [!] 疑似モジュールパス構築に必要

local M = {}

---
-- プロジェクトの全コンポーネントのキャッシュを削除するコアロジック
-- @param maps table core_utils.get_project_mapsの結果
local function execute_project_cleanup(maps)
  local log = uep_log.get()
  local project_display_name = vim.fn.fnamemodify(maps.project_root, ":t")

  -- 1. ユーザーへの最終確認（vim.fn.confirmは同期処理）
  local prompt_str = ("Permanently delete ALL structural and module cache files for project '%s'? (Run :UEP refresh afterwards)"):format(project_display_name)
  local choices = "&Yes\n&No"
  local decision = vim.fn.confirm(prompt_str, choices, 2)

  if decision ~= 1 then
    return log.info("Project cleanup cancelled by user.")
  end

  -- Yesが選択された (decision == 1) 場合の処理

  local components_to_clean = vim.tbl_values(maps.all_components_map)
  if #components_to_clean == 0 then
    return log.warn("No components found in maps to clean.")
  end

  -- タスク総数を見積もる (コンポーネント数 + 全モジュール数 + 疑似モジュール数 + レジストリ削除1)
  local total_components = #components_to_clean
  local total_modules = vim.tbl_count(maps.all_modules_map)
  
  -- 疑似モジュールの数をカウント
  local pseudo_module_count = 0
  if maps.engine_root then
      pseudo_module_count = pseudo_module_count + 3 -- _EngineConfig, _EngineShaders, _EnginePrograms
  end
  for _, comp_meta in pairs(maps.all_components_map) do
    if (comp_meta.type == "Game" or comp_meta.type == "Plugin") and comp_meta.root_path then
      pseudo_module_count = pseudo_module_count + 1
    end
  end

  local total_tasks = total_components + total_modules + pseudo_module_count + 1 -- [!] レジストリ削除(1)を追加
  local deleted_count = 0

  -- 2. プログレスバーの初期化
  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, {
    title = ("UEP: Cleaning up %s..."):format(project_display_name),
    client_name = "UEP.Cleanup",
    weights = { cleanup_tasks = 1.0 },
  })
  progress:open()
  progress:stage_define("cleanup_tasks", total_tasks)

  local current_task_count = 0
  local function update_progress(display_name, type)
    current_task_count = current_task_count + 1
    local msg = ("Deleting %s cache for %s... [%d/%d]"):format(type, display_name, current_task_count, total_tasks)
    progress:stage_update("cleanup_tasks", current_task_count, msg)
  end

  local function run_cleanup_async()
    local db = uep_db.get()
    if db then
        -- A. DBから全データを削除 (CASCADE設定により関連テーブルも削除されるはず)
        update_progress("All Components", "DB Cleanup")
        db:eval("DELETE FROM components")
        
        update_progress("All Modules", "DB Cleanup")
        db:eval("DELETE FROM modules")
        
        -- files, classes, directories は modules 削除時に CASCADE される想定だが
        -- 念のため明示的に削除しても良い (が、CASCADEなら不要)
        -- db:eval("DELETE FROM files")
        
        deleted_count = total_components + total_modules + pseudo_module_count
    else
        log.error("Could not open DB for cleanup.")
    end

    -- D. マスターレジストリからこのプロジェクトを削除
    log.debug("Removing current project '%s' from master registry (projects.json)...", project_display_name)
    update_progress(project_display_name, "Master Registry")
    
    -- projects_cache.remove_project は load と save を内包している
    local remove_ok = projects_cache.remove_project(project_display_name)
    if remove_ok then
        deleted_count = deleted_count + 1
        -- 最後のタスクとしてプログレスを更新
        current_task_count = current_task_count + 1
        progress:stage_update("cleanup_tasks", current_task_count, "Removed project from master registry.")
    else
        log.error("Failed to remove project '%s' from master registry.", project_display_name)
    end

    -- 3. 終了処理
    progress:finish(true)
    log.info("Cleanup completed for project '%s'. DB records were cleared. Please run :UEP refresh.", project_display_name)
    vim.notify(string.format("Cleanup complete. Run :UEP refresh to rebuild caches."), vim.log.levels.INFO)
  end

  -- 3. メインの処理を遅延実行
  vim.defer_fn(run_cleanup_async, 10)
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 1. プロジェクトルートを取得し、レジストリ情報を確認
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      local project_root = require("UNL.finder").project.find_project_root(vim.loop.cwd())
      if project_root then
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
