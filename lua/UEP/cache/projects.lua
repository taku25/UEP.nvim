-- lua/UEP/cache/projects.lua (最終確定版)

-- 必要なUNLのコアモジュールをインポート
local unl_cache_core = require("UNL.cache.core")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
-- Neovimの標準モジュール
local fs = require("vim.fs")
local json = vim.json

local M = {}

local CACHE_FILENAME = "projects.json"

---
-- キャッシュファイルのフルパスを正しく構築する
--
local function get_cache_path()
  -- 1. 現在の有効な設定を取得する
  local conf = uep_config.get()
  
  -- 2. UNLのコア関数を呼び出す。
  --    UEP/init.lua の設定により、これは ".../cache/UEP" というパスを返す
  local base_dir = unl_cache_core.get_cache_dir(conf)
  
  -- 3. ベースディレクトリとファイル名を結合する
  return fs.joinpath(base_dir, CACHE_FILENAME)
end


-- 以下の load, save, add_or_update, remove 関数は、
-- get_cache_path() のロジックに依存しているため、変更は一切不要です。

function M.load()
  local path = get_cache_path()
  if vim.fn.filereadable(path) == 0 then return nil end
  return require("UNL.cache.core").load_json(path)
end

local function save(projects_data)
  local path = get_cache_path()
  -- 汎用セーブ関数を呼び出すだけ！
  local ok, err = unl_cache_core.save_json(path, projects_data)
  if not ok then
    -- エラーハンドリング (必要に応じて)
    require("UEP.logger").get().error("Failed to save projects.json: %s", tostring(err))
  end
  unl_events.publish(unl_event_types.ON_AFTER_PROJECTS_CACHE_SAVE, {
    status = "success",
  })
  
  return ok
end

function M.add_or_update(project_info)
  -- 1. キャッシュをロードし、もしnilなら空のテーブル{}を代わりに使う
  local projects = M.load() or {}
  
  -- 2. プロジェクト名を取得
  local project_name = vim.fn.fnamemodify(project_info.uproject_path, ":t:r")

  -- 3. データを更新または追加
  projects[project_info.root] = {
    name = project_name,
    uproject_path = project_info.uproject_path,
    engine_root_path = project_info.engine_root_path,
    last_indexed_at = os.time()
  }
  
  -- 4. 保存
  save(projects)
end

function M.remove(project_root)
  local projects = M.load()
  if projects and projects[project_root] then -- ★ projectsがnilでないこともチェック
    projects[project_root] = nil
    return save(projects) -- ★ save関数の結果(true/false)をそのまま返す
  end
  return true
end

return M
