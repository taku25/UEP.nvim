-- lua/UEP/cache/symbols.lua (新スコープ・新Depsフラグ対応版)

local unl_cache_core = require("UNL.cache.core")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local unl_path = require("UNL.path")
local unl_finder = require("UNL.finder")
local uep_context = require("UEP.context") -- ★ オンメモリキャッシュ用

local M = {}

local MAGIC_CODE = "UEP Symbol Cache V2" -- ★ バージョン更新
local CACHE_VERSION = "2.0" -- ★ バージョン更新

-- ▼▼▼ get_symbol_cache_path を修正 ▼▼▼
---
-- スコープと依存フラグからキャッシュファイルパスを取得する
-- @param scope string "game", "engine", "runtime", "developer", "editor", "full"
-- @param deps_flag string "--deep-deps", "--shallow-deps", "--no-deps"
-- @return string|nil キャッシュファイルのフルパス or nil
local function get_symbol_cache_path(scope, deps_flag)
  -- デフォルト値の決定 (呼び出し元で行う方がより安全だが、ここでも設定)
  scope = scope or "runtime"
  deps_flag = deps_flag or "--deep-deps"

  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end

  local project_name = unl_path.normalize(project_root):gsub("[\\/:]", "_")
  local conf = uep_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  local cmd_cache_dir = fs.joinpath(base_dir, "cmd")

  local scope_suffix = "_" .. scope:lower()
  -- ★★★ deps_suffix に shallowdeps を追加 ★★★
  local deps_suffix = ""
  if deps_flag == "--shallow-deps" then deps_suffix = "_shallowdeps"
  elseif deps_flag == "--no-deps" then deps_suffix = "_nodeps"
  else deps_suffix = "_deepdeps" end -- デフォルトは deep

  local filename = project_name .. ".symbols" .. scope_suffix .. deps_suffix .. ".cache.json"

  return fs.joinpath(cmd_cache_dir, filename)
end
-- ▲▲▲ get_symbol_cache_path 修正ここまで ▲▲▲


-- ▼▼▼ get_context_key を追加 ▼▼▼
local function get_context_key(scope, deps_flag)
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end

  local scope_suffix = scope:lower()
  local deps_suffix = ""
  if deps_flag == "--shallow-deps" then deps_suffix = "shallow"
  elseif deps_flag == "--no-deps" then deps_suffix = "no"
  else deps_suffix = "deep" end

  return "symbol_cache::" .. project_root .. "::" .. scope_suffix .. "::" .. deps_suffix
end
-- ▲▲▲ get_context_key 追加ここまで ▲▲▲


-- ▼▼▼ M.save を修正 (オンメモリキャッシュ対応) ▼▼▼
function M.save(symbol_list, scope, deps_flag)
  local log = uep_log.get() -- ★ ログ取得
  local path = get_symbol_cache_path(scope, deps_flag)
  local context_key = get_context_key(scope, deps_flag) -- ★ コンテキストキー取得
  if not path or not context_key then return false end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local data_to_save = {
    magic_code = MAGIC_CODE,
    version = CACHE_VERSION,
    symbols = symbol_list,
  }

  local ok, err = unl_cache_core.save_json(path, data_to_save)
  if not ok then
    log.error("Failed to save symbol cache (scope=%s, deps=%s): %s", scope, deps_flag, tostring(err))
    return false
  end
  -- ★ オンメモリキャッシュも更新 (シンボルリストのみ)
  uep_context.set(context_key, symbol_list)
  log.info("Saved %d symbols to cache (scope=%s, deps=%s): %s", #symbol_list, scope, deps_flag, path)
  return true
end
-- ▲▲▲ M.save 修正ここまで ▲▲▲


-- ▼▼▼ M.load を修正 (オンメモリキャッシュ対応) ▼▼▼
function M.load(scope, deps_flag)
  local log = uep_log.get() -- ★ ログ取得
  local context_key = get_context_key(scope, deps_flag)
  if not context_key then return nil end

  -- 1. オンメモリキャッシュを確認
  local cached_symbols = uep_context.get(context_key)
  if cached_symbols then
      log.debug("Loaded %d symbols from in-memory cache (scope=%s, deps=%s)", #cached_symbols, scope, deps_flag)
      return cached_symbols
  end

  -- 2. ディスクキャッシュを確認
  local path = get_symbol_cache_path(scope, deps_flag)
  if not path or vim.fn.filereadable(path) == 0 then return nil end

  local file_data = unl_cache_core.load_json(path)

  -- バージョン/マジックコード/データ構造チェック
  if not file_data or file_data.magic_code ~= MAGIC_CODE or file_data.version ~= CACHE_VERSION or
     not file_data.symbols or type(file_data.symbols) ~= "table" then
    log.warn("Symbol cache (scope=%s, deps=%s) is invalid or outdated. Ignoring & deleting: %s", scope, deps_flag, path)
    pcall(vim.loop.fs_unlink, path) -- 古い/不正なキャッシュは削除
    return nil
  end

  -- 3. オンメモリに保存して返す
  uep_context.set(context_key, file_data.symbols)
  log.debug("Loaded %d symbols from disk cache (scope=%s, deps=%s): %s", #file_data.symbols, scope, deps_flag, path)
  return file_data.symbols
end
-- ▲▲▲ M.load 修正ここまで ▲▲▲


-- ▼▼▼ M.delete を修正 (全スコープ・全Depsフラグ対応) ▼▼▼
function M.delete()
   local log = uep_log.get() -- ★ ログ取得
   -- ★★★ 全てのスコープとDepsフラグの組み合わせを削除対象とする ★★★
   local scopes = {"game", "engine", "runtime", "developer", "editor", "full"}
   local flags = {"--deep-deps", "--shallow-deps", "--no-deps"}
   local deleted_any = false
   local errors = {}

   for _, s in ipairs(scopes) do
       for _, f in ipairs(flags) do
           local path = get_symbol_cache_path(s, f)
           local context_key = get_context_key(s, f) -- ★ 対応するコンテキストキー

           -- ディスク上のファイルを削除
           if path and vim.fn.filereadable(path) == 1 then
             local ok, err = pcall(vim.loop.fs_unlink, path)
             if ok then
                log.info("Deleted symbol cache file (scope=%s, deps=%s): %s", s, f, path)
                deleted_any = true
             else
                local err_msg = ("Failed to delete symbol cache (scope=%s, deps=%s) %s: %s"):format(s, f, path, tostring(err))
                log.error(err_msg)
                table.insert(errors, err_msg)
             end
          end
          -- オンメモリキャッシュを削除
          if context_key then
              uep_context.del(context_key)
              log.trace("Deleted in-memory symbol cache key: %s", context_key)
          end
      end
   end
   -- エラーがなければ成功
   return #errors == 0
end
-- ▲▲▲ M.delete 修正ここまで ▲▲▲

return M
