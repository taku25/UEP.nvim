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
  -- 1. Game側のプロジェクトデータとファイルキャッシュをロード
  local game_project_data = ProjectCache.load(opts.project_root)
  local game_file_cache = FilesDiskCache.load(opts.project_root)

  -- 2. Gameキャッシュの鮮度をチェック
  if not (game_project_data and game_file_cache and game_file_cache.generation == game_project_data.generation) then
    uep_log.get().warn("Game file cache is outdated or missing. Please run :UEP refresh")
    return nil
  end

  -- 3. 全てのモジュールのファイルリストを格納する単一のテーブルを準備
  local all_files_by_module = {}

  -- ★★★ 修正点: 正しいJSON構造からデータを読み込む ★★★
  -- 4. Gameキャッシュのファイルを追加
  if game_file_cache and game_file_cache.modules_data then
    for module_name, module_data in pairs(game_file_cache.modules_data) do
      if module_data and module_data.files then
        all_files_by_module[module_name] = module_data.files
      end
    end
  end
  
  -- 5. Engine側のデータをロードし、有効ならファイルを追加
  if opts.engine_root then
    local engine_project_data = ProjectCache.load(opts.engine_root)
    local engine_file_cache = FilesDiskCache.load(opts.engine_root)
    
    if engine_project_data and engine_file_cache and engine_file_cache.generation == engine_project_data.generation then
      if engine_file_cache.modules_data then
        for module_name, module_data in pairs(engine_file_cache.modules_data) do
          if module_data and module_data.files and not all_files_by_module[module_name] then
            all_files_by_module[module_name] = module_data.files
          end
        end
      end
    end
  end
  
  -- 6. 要求されたモジュールリストに基づいて、最終的なファイルリストを作成
  local final_files = {}
  if opts.required_modules then
    for _, module_name in ipairs(opts.required_modules) do
      if all_files_by_module[module_name] then
        for _, file_path in ipairs(all_files_by_module[module_name]) do
          table.insert(final_files, file_path)
        end
      end
    end
  end

  return final_files
end

return M
