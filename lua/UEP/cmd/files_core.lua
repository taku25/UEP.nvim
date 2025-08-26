-- lua/UEP/cmd/files_core.lua

local ProjectCache = require("UEP.cache.project")
local FilesDiskCache = require("UEP.cache.files")
local uep_log      = require("UEP.logger")

local M = {}

-- ★★★ 新しい妥当性チェック関数 ★★★
-- キャッシュが最新で、矛盾がないかをチェックするだけ。
-- 成功すればtrue、失敗すればfalseを返す。
function M.is_cache_valid(project_root)
  -- 1. Game側のプロジェクトデータをロード
  local game_project_data = ProjectCache.load(project_root)
  if not (game_project_data and game_project_data.generation) then
    uep_log.get().warn("is_cache_valid: Game project data or its generation is missing.")
    return false
  end

  -- 2. Game側のファイルキャッシュをディスクからロード
  local game_file_cache = FilesDiskCache.load(project_root)
  
  -- 3. Engine側のデータをロード
  local engine_project_data
  local engine_file_cache
  if game_project_data.link_engine_cache_root then
    engine_project_data = ProjectCache.load(game_project_data.link_engine_cache_root)
    if engine_project_data then
      engine_file_cache = FilesDiskCache.load(engine_project_data.root)
    end
  end
  
  -- 4. Gameキャッシュの鮮度をチェック
  if not (game_file_cache and game_file_cache.Game and game_file_cache.Game.generation == game_project_data.generation) then
    uep_log.get().warn("is_cache_valid: Game file cache is not valid or outdated.")
    return false
  end

  -- 5. Engineキャッシュも存在すれば、鮮度をチェック
  if engine_project_data then
    if not (engine_file_cache and engine_file_cache.Engine and engine_file_cache.Engine.generation == engine_project_data.generation) then
      uep_log.get().warn("is_cache_valid: Engine file cache is not present or is outdated.")
      return false
    end
  end

  -- 全てのチェックをパス
  return true
end




function M.get_files_from_cache(opts)
  -- 1. Game側のプロジェクトデータをロード
  local game_project_data = ProjectCache.load(opts.project_root)
  if not (game_project_data and game_project_data.generation) then return nil end

  -- 2. Game側のファイルキャッシュをディスクからロード
  local game_file_cache = FilesDiskCache.load(opts.project_root)
  
  -- 3. Engine側のデータをロード
  local engine_project_data
  local engine_file_cache
  if opts.engine_root then
    engine_project_data = ProjectCache.load(opts.engine_root)
    if engine_project_data then
      engine_file_cache = FilesDiskCache.load(engine_project_data.root)
    end
  end
  
  -- 4. Gameキャッシュの鮮度をチェック (新しいフラット構造に対応)
  if not (game_file_cache and game_file_cache.generation == game_project_data.generation) then
    uep_log.get().warn("Game file cache is outdated. Please run :UEP refresh")
    return nil
  end

   -- ★★★ ここからが最後の修正 ★★★
  -- 5. GameとEngineのファイルリストを「手動のforループ」で一つに結合
  local all_available_files = {}

  -- Gameキャッシュのファイルを追加
   -- 4. Gameキャッシュの鮮度をチェック (フラットな構造に対応)
  if not (game_file_cache and game_file_cache.generation == game_project_data.generation) then
    vim.notify("Game file cache is outdated. Please run :UEP refresh", vim.log.levels.WARN)
    return nil
  end

  -- 5. GameとEngineのファイルリストを一つに結合
  local all_available_files = {}
  if game_file_cache.files_by_module then
    for module_name, files in pairs(game_file_cache.files_by_module) do
      all_available_files[module_name] = files
    end
  end
  
  -- Engineキャッシュも有効なら結合 (フラットな構造に対応)
  if engine_project_data and engine_file_cache and engine_file_cache.generation == engine_project_data.generation then
    if engine_file_cache.files_by_module then
      for module_name, files in pairs(engine_file_cache.files_by_module) do
        if not all_available_files[module_name] then
          all_available_files[module_name] = files
        end
      end
    end
  end
  
  -- 6. 結合されたリストの中から、要求されたモジュールのファイルを探す
  local final_files = {}
  for _, module_name in ipairs(opts.required_modules) do
    if all_available_files[module_name] then
      vim.list_extend(final_files, all_available_files[module_name])
    end
  end

  return final_files
end
return M
