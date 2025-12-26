-- lua/UEP/cache/module.lua (Engine モジュールのみ詳細ログ版 - 完全版)

local uep_config = require("UEP.config")
local unl_cache_core = require("UNL.cache.core")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local unl_path = require("UNL.path")
local uep_context = require("UEP.context")
local db_writer = require("UEP.db.writer")

local M = {}

local MAGIC_CODE = "UEP Module Cache"
local CACHE_VERSION = "1.0" -- Or 2.0 if you updated it

local function get_name_from_root(root_path)
  if not root_path then return nil end
  return unl_path.normalize(root_path):gsub("[\\/:]", "_")
end

local function get_cache_path(module_meta)
  local log = uep_log.get()
  if not (module_meta and module_meta.module_root) then
    log.warn("get_cache_path: module_meta.module_root is nil for module '%s'.", module_meta and module_meta.name or "UNKNOWN")
    return nil
  end

  local conf = uep_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  if not base_dir then log.error("get_cache_path: Could not get cache base directory."); return nil end

  local modules_dir = fs.joinpath(base_dir, "modules")

  local unique_filename = get_name_from_root(module_meta.module_root)
  if not unique_filename then log.error("get_cache_path: Failed to generate unique filename from root '%s'", module_meta.module_root); return nil end

  local filename = ("%s.module.json"):format(unique_filename)
  return fs.joinpath(modules_dir, filename)
end

local function get_context_key(module_meta)
  if not (module_meta and module_meta.module_root) then return nil end
  return "module_cache::" .. module_meta.module_root
end

---
-- モジュールキャッシュをディスクに保存し、オンメモリキャッシュも更新する
function M.save(module_meta, data)
  local log = uep_log.get()
  local module_name = module_meta and module_meta.name or "UNKNOWN_MODULE"
  local is_engine_module = (module_name == "Engine") -- ★ Engine モジュールかどうかのフラグ

  -- ▼▼▼ Engine モジュールの場合のみ trace ログを出力 ▼▼▼
  if is_engine_module then
    log.trace("module_cache.save: ENTERED for module '%s'", module_name)
  end
  -- ▲▲▲ ここまで ▲▲▲

  -- ヘッダ詳細に何件のクラスがあるかを記録
  local hdr_count, cls_count = 0, 0
  if data.header_details then
    for _, info in pairs(data.header_details) do
      hdr_count = hdr_count + 1
      if info.classes then cls_count = cls_count + #info.classes end
    end
  end
  if hdr_count > 0 then
    log.debug("module_cache.save: header_details=%d, classes=%d for '%s'", hdr_count, cls_count, module_name)
  end

  -- SQLiteに移行のため、JSONファイル保存をスキップ
  -- SQLiteにのみデータを保存
  db_writer.save_module_files(module_meta, data.files, data.header_details)

  -- オンメモリキャッシュ更新
  local context_key = get_context_key(module_meta)
  if context_key then
      -- ▼▼▼ Engine モジュールの場合のみ trace ログを出力 ▼▼▼
      if is_engine_module then
        log.trace("module_cache.save: Updating in-memory cache for '%s' with key '%s'", module_name, context_key)
      end
      -- ▲▲▲ ここまで ▲▲▲
      uep_context.set(context_key, data) -- data 全体を保存
  else
      log.warn("module_cache.save: Could not get context key for '%s' after saving.", module_name) -- ★ 警告は常に出力
  end

  -- ▼▼▼ Engine モジュールの場合のみ trace ログを出力 ▼▼▼
  if is_engine_module then
    log.trace("module_cache.save: COMPLETED successfully for module '%s'", module_name)
  end
  -- ▲▲▲ ここまで ▲▲▲
  return true
end

-- ( M.load, M.delete は変更なし )
function M.load(module_meta)
  local log = uep_log.get()
  if not (module_meta and module_meta.module_root) then return nil end
  local context_key = get_context_key(module_meta)
  if not context_key then return nil end

  local cached_data = uep_context.get(context_key)
  if cached_data then return cached_data end

  local path = get_cache_path(module_meta)
  if not path or vim.fn.filereadable(path) == 0 then return nil end
  local file_data = unl_cache_core.load_json(path)

  if not file_data or file_data.magic_code ~= MAGIC_CODE or file_data.version ~= CACHE_VERSION then
    log.warn("Module cache for '%s' is outdated or invalid. Ignoring.", module_meta.name)
    return nil
  end

  uep_context.set(context_key, file_data)
  return file_data -- ★ file_data 全体を返す (load_symbol_list とは違う)
end

function M.delete(module_meta)
  if not (module_meta and module_meta.module_root) then return false end
  local log = uep_log.get()
  local path = get_cache_path(module_meta)
  if not path then return false end
  local context_key = get_context_key(module_meta)
  if context_key then uep_context.del(context_key) end

  local stat = vim.loop.fs_stat(path)
  if stat then
    local ok, err = vim.loop.fs_unlink(path)
    if ok then
      log.trace("Successfully deleted module cache: %s", path)
      return true
    else
      log.error("Failed to delete module cache %s: %s", path, tostring(err))
      return false
    end
  end
  return true
end

return M
