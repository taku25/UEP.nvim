-- lua/UEP/provider/class.lua (インテリジェント・アグリゲーター最終完成版)

local files_disk_cache = require("UEP.cache.files")
local project_cache = require("UEP.cache.project")
local unl_finder = require("UNL.finder")
local uep_log = require("UEP.logger").get()

local M = {}

---
-- プロジェクトの依存関係を元に、必要なモジュールからのみheader_detailsを集約して返す。
function M.request(opts)
  opts = opts or {}
  uep_log.debug("--- UEP Provider 'get_project_classes' CALLED (Intelligent Mode) ---")

  local project_root = opts.project_root or unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end

  -- STEP 1: コンテキストを理解するために、GameとEngineのプロジェクトデータを両方ロード
  local game_project_data = project_cache.load(project_root)
  if not (game_project_data and game_project_data.modules) then
    uep_log.warn("Provider WARNING: Game project data or modules not found for %s.", project_root)
    return nil
  end
  local engine_root = game_project_data.link_engine_cache_root
  local engine_project_data = engine_root and project_cache.load(engine_root)

  -- STEP 2: ターゲットとなるモジュールの完全なリストを作成する
  local target_module_names = {}
  local all_modules_meta = vim.tbl_deep_extend("force", {}, engine_project_data and engine_project_data.modules or {}, game_project_data.modules)

  -- 2a. まず、Gameプロジェクト自身のモジュールを全てターゲットに追加
  for module_name, _ in pairs(game_project_data.modules) do
    target_module_names[module_name] = true
  end

  -- 2b. 次に、それらのモジュールの深い依存関係(deep_dependencies)を全てターゲットに追加
  for module_name, _ in pairs(game_project_data.modules) do
    local module_meta = all_modules_meta[module_name]
    if module_meta and module_meta.deep_dependencies then
      for _, dep_name in ipairs(module_meta.deep_dependencies) do
        target_module_names[dep_name] = true
      end
    end
  end

  -- STEP 3: GameとEngineの両方のファイルキャッシュをロード
  local game_files_cache = files_disk_cache.load(project_root)
  local engine_files_cache = engine_root and files_disk_cache.load(engine_root)
  
  -- STEP 4: 全てのモジュールデータを一つのテーブルにマージして、検索しやすくする
  local all_modules_data = vim.tbl_deep_extend("force", {}, engine_files_cache and engine_files_cache.modules_data or {}, game_files_cache and game_files_cache.modules_data or {})

  -- STEP 5: ターゲットリストを元に、精密な情報収集を行う
  local merged_header_details = {}
  for module_name, _ in pairs(target_module_names) do
    local module_data = all_modules_data[module_name]
    if module_data and module_data.header_details then
      -- 信頼できる手動マージ
      for file_path, details in pairs(module_data.header_details) do
        merged_header_details[file_path] = details
      end
    end
  end

  local final_count = vim.tbl_count(merged_header_details)
  uep_log.info("Provider: finished. Returning %d relevant header details from %d target modules.", final_count, vim.tbl_count(target_module_names))
  
  return merged_header_details
end

return M
