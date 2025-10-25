-- lua/UEP/cache/module.lua
-- (ファイル名にフルパスを使う修正版)

local uep_config = require("UEP.config")
local unl_cache_core = require("UNL.cache.core")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local unl_path = require("UNL.path")
local uep_context = require("UEP.context")

local M = {}

local MAGIC_CODE = "UEP Module Cache"
local CACHE_VERSION = "1.0"

-- ▼▼▼ projects.lua からヘルパー関数を拝借 ▼▼▼
local function get_name_from_root(root_path)
  if not root_path then return nil end
  return unl_path.normalize(root_path):gsub("[\\/:]", "_")
end
-- ▲▲▲ ここまで ▲▲▲

---
-- モジュールのメタデータからキャッシュファイルのフルパスを取得する
-- @param module_meta table (モジュール名とmodule_rootを含むテーブル)
-- @return string|nil キャッシュパス
local function get_cache_path(module_meta)
  if not (module_meta and module_meta.module_root) then 
    uep_log.get().warn("get_cache_path: module_meta.module_root is nil.")
    return nil 
  end
  
  local conf = uep_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  if not base_dir then return nil end
  
  local modules_dir = fs.joinpath(base_dir, "modules")
  
  -- ▼▼▼ 修正点: ファイル名をフルパスから生成 ▼▼▼
  -- 例: "C:/.../ImGui" -> "C_Users_..._ImGui.module.json"
  local unique_filename = get_name_from_root(module_meta.module_root)
  if not unique_filename then return nil end
  
  local filename = ("%s.module.json"):format(unique_filename)
  -- ▲▲▲ 修正ここまで ▲▲▲
  
  return fs.joinpath(modules_dir, filename)
end

---
-- モジュールメタデータからオンメモリキャッシュ用のキーを取得する
-- @param module_meta table
-- @return string
local function get_context_key(module_meta)
  -- ★ フルパス（module_root）は最高のユニークキーになる
  return "module_cache::" .. module_meta.module_root
end

---
-- モジュールキャッシュをディスクに保存し、オンメモリキャッシュも更新する
-- @param module_meta table
-- @param data table 保存するデータ
-- @return boolean 成功したか
function M.save(module_meta, data)
  local path = get_cache_path(module_meta)
  if not path then return false end
  
  data.magic_code = MAGIC_CODE
  data.version = CACHE_VERSION
  
  local ok, err = unl_cache_core.save_json(path, data)
  if not ok then
    uep_log.get().error("Failed to save module cache to %s: %s", path, tostring(err))
    return false
  end
  
  uep_context.set(get_context_key(module_meta), data)
  return true
end

---
-- モジュールキャッシュを読み込む (オンメモリキャッシュ優先)
-- @param module_meta table
-- @return table|nil キャッシュデータ
function M.load(module_meta)
  if not (module_meta and module_meta.module_root) then return nil end
  
  local path = get_cache_path(module_meta)
  if not path then return nil end
  
  local context_key = get_context_key(module_meta)

  -- 1. まずオンメモリキャッシュを確認
  local cached_data = uep_context.get(context_key)
  if cached_data then
    return cached_data
  end

  -- 2. なければディスクから読む
  if vim.fn.filereadable(path) == 0 then return nil end
  local file_data = unl_cache_core.load_json(path)

  if not file_data or file_data.magic_code ~= MAGIC_CODE or file_data.version ~= CACHE_VERSION then
    uep_log.get().warn("Module cache for '%s' is outdated or invalid. Ignoring.", module_meta.name)
    return nil
  end
  
  -- 3. 読んだデータをオンメモリキャッシュに保存
  uep_context.set(context_key, file_data)
  return file_data
end

---
-- モジュールキャッシュをディスクとオンメモリの両方から削除する
-- @param module_meta table
-- @return boolean 成功したか
function M.delete(module_meta)
  if not (module_meta and module_meta.module_root) then return false end
  
  local log = uep_log.get()
  local path = get_cache_path(module_meta)
  if not path then return false end
  
  -- 1. オンメモリキャッシュをクリア
  uep_context.del(get_context_key(module_meta))

  -- 2. ディスク上のファイルを削除
  local stat = vim.loop.fs_stat(path)
  if stat then
    local ok, err = vim.loop.fs_unlink(path)
    if ok then
      log.info("Successfully deleted module cache: %s", path)
      return true
    else
      log.error("Failed to delete module cache %s: %s", path, tostring(err))
      return false
    end
  end
  
  return true -- ファイルが存在しない場合は成功
end

return M
