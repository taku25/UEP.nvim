-- lua/UEP/cache/symbols.lua (deps_flag 対応・cmd サブディレクトリ保存版)

local unl_cache_core = require("UNL.cache.core")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local unl_path = require("UNL.path")
local unl_finder = require("UNL.finder")

local M = {}

local MAGIC_CODE = "UEP Symbol Cache"
local CACHE_VERSION = "1.0" -- シンボルキャッシュ専用バージョン

---
-- プロジェクト名と依存フラグからキャッシュファイルパスを取得する
-- @param deps_flag string "--no-deps" または "--all-deps"
-- @return string|nil キャッシュファイルのフルパス or nil
local function get_symbol_cache_path(scope, deps_flag)
  -- デフォルト値の決定
  scope = scope or "Editor"
  deps_flag = (deps_flag == "--all-deps") and "--all-deps" or "--no-deps"

  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end

  local project_name = unl_path.normalize(project_root):gsub("[\\/:]", "_")
  local conf = uep_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  local cmd_cache_dir = fs.joinpath(base_dir, "cmd")

  -- ▼▼▼【修正点】スコープと依存フラグをファイル名に含める ▼▼▼
  local scope_suffix = "_" .. scope:lower() -- 例: _full, _game, _engine
  local deps_suffix = (deps_flag == "--all-deps") and "_alldeps" or "_nodeps"

  -- ファイル名: [プロジェクト名].symbols_[scope]_alldeps.cache.json
  local filename = project_name .. ".symbols" .. scope_suffix .. deps_suffix .. ".cache.json"

  return fs.joinpath(cmd_cache_dir, filename)
end

---
-- シンボルリストを指定された依存フラグのキャッシュに保存する
-- @param symbol_list table 保存するシンボルリスト
-- @param deps_flag string "--no-deps" または "--all-deps"
-- @return boolean 保存に成功したかどうか
function M.save(symbol_list, scope, deps_flag)
  local path = get_symbol_cache_path(scope, deps_flag)
  if not path then return false end

  -- 保存前に cmd ディレクトリを作成 (files.lua と同様)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local data_to_save = {
    magic_code = MAGIC_CODE,
    version = CACHE_VERSION,
    symbols = symbol_list,
  }

  local ok, err = unl_cache_core.save_json(path, data_to_save)
  if not ok then
    uep_log.get().error("Failed to save symbol cache (%s): %s", deps_flag, tostring(err))
    return false
  end
  uep_log.get().info("Saved %d symbols to cache (%s): %s", #symbol_list, deps_flag, path)
  return true
end

---
-- 指定された依存フラグのキャッシュからシンボルリストを読み込む
-- @param deps_flag string "--no-deps" または "--all-deps"
-- @return table|nil シンボルリスト or nil (キャッシュ無効/失敗時)
function M.load(scope, deps_flag)
  local path = get_symbol_cache_path(scope, deps_flag)
  if not path or vim.fn.filereadable(path) == 0 then return nil end

  local file_data = unl_cache_core.load_json(path)

  -- バージョン/マジックコード/データ構造チェック
  if not file_data or file_data.magic_code ~= MAGIC_CODE or file_data.version ~= CACHE_VERSION or
     not file_data.symbols or type(file_data.symbols) ~= "table" then
    uep_log.get().warn("Symbol cache (%s) is invalid or corrupted. Ignoring & deleting: %s", deps_flag, path)
    pcall(vim.loop.fs_unlink, path) -- 古い/不正なキャッシュは削除
    return nil
  end

  uep_log.get().debug("Loaded %d symbols from cache (%s): %s", #file_data.symbols, deps_flag, path)
  return file_data.symbols
end

---
-- プロジェクトのシンボルキャッシュファイル (--no-deps と --all-deps 両方) を削除する
-- @return boolean 少なくとも1つのファイルが削除されたか、元々存在しなかった場合は true
function M.delete()
   local scopes = {"Editor", "Game", "Engine"} -- [!] 削除対象のスコープを追加
   local flags = {"--no-deps", "--all-deps"}
   for _, s in ipairs(scopes) do
       for _, f in ipairs(flags) do
           local path = get_symbol_cache_path(s, f) -- [!] s, f を渡す
           if path and vim.fn.filereadable(path) == 1 then
             local ok, err = pcall(vim.loop.fs_unlink, path)
             if ok then
                uep_log.get().info("Deleted symbol cache (%s): %s", flag, path)
                deleted_any = true
             else
                local err_msg = ("Failed to delete symbol cache (%s) %s: %s"):format(flag, path, tostring(err))
                uep_log.get().error(err_msg)
                table.insert(errors, err_msg)
             end
          end
      end
   end
   -- エラーがなければ成功、ファイルが存在しなくても成功
   return #errors == 0
end

return M
