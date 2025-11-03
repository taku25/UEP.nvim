-- From: lua\UEP\cmd\cleanup.lua
-- lua/UEP/cmd/cleanup.lua (モジュールキャッシュ対応版)

local core_utils = require("UEP.cmd.core.utils")
local project_cache = require("UEP.cache.project")
-- local files_cache_manager = require("UEP.cache.files") -- [!] 削除
local module_cache = require("UEP.cache.module") -- [!] 追加
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
  -- [!] メッセージを「構造」と「モジュール」キャッシュに変更
  local prompt_str = ("Permanently delete ALL structural and module cache files for project '%s'? (Run :UEP refresh afterwards)"):format(project_display_name)
  local choices = "&Yes\n&No"
  local decision = vim.fn.confirm(prompt_str, choices, 2)

  if decision ~= 1 then
    return log.info("Project cleanup cancelled by user.")
  end

  -- Yesが選択された (decision == 1) 場合の処理

  -- [!] maps.all_components_map を使う
  local components_to_clean = vim.tbl_values(maps.all_components_map)
  if #components_to_clean == 0 then
    return log.warn("No components found in maps to clean.")
  end

  -- タスク総数を見積もる (コンポーネント数 + 全モジュール数)
  local total_components = #components_to_clean
  local total_modules = vim.tbl_count(maps.all_modules_map)
  local total_tasks = total_components + total_modules
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
    -- A. 全コンポーネントの「構造キャッシュ (*.project.json)」を削除
    for _, component in ipairs(components_to_clean) do
      local project_cache_filename = component.name .. ".project.json"
      update_progress(component.display_name, "Project Structural")
      if project_cache.delete_component_cache_file(project_cache_filename) then
        deleted_count = deleted_count + 1
      end
    end

    -- B. 全モジュールの「モジュールキャッシュ (*.module.json)」を削除
    -- [!] maps.all_modules_map をイテレートする
    for mod_name, mod_meta in pairs(maps.all_modules_map) do
      update_progress(mod_name, "Module")
      if module_cache.delete(mod_meta) then
        deleted_count = deleted_count + 1
      end
    end

    -- 3. 終了処理
    progress:finish(true)
    log.info("Cleanup completed for project '%s'. %d cache files were cleared. Please run :UEP refresh.", project_display_name, deleted_count)
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
