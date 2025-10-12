-- lua/UEP/cache/project.lua (local functionバグ修正版)

local uep_config = require("UEP.config")
local unl_cache_core = require("UNL.cache.core")
local fs = require("vim.fs")
local uep_context = require("UEP.context")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")

local M = {}

local MAGIC_CODE = "UEP Project Cache"
local CACHE_VERSION = 1

local function get_cache_path(cache_filename)
  if not cache_filename then return nil end
  local conf = uep_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  local projects_dir = fs.joinpath(base_dir, "projects")
  return fs.joinpath(projects_dir, cache_filename)
end

local function get_context_key_name(cache_filename)
  return "project_cache::" .. cache_filename
end

---
-- ▼▼▼ ここを `function M.save` に修正しました ▼▼▼
function M.save(cache_filename, data)
  local path = get_cache_path(cache_filename)
  if not path then return false, "Could not generate cache path." end

  data.magic_code = MAGIC_CODE
  data.version = CACHE_VERSION

  local ok, err = unl_cache_core.save_json(path, data)
  if not ok then
    local err_msg = ("Failed to save project cache to %s: %s"):format(path, tostring(err))
    require("UEP.logger").get().error(err_msg)
    return false, err_msg
  end

  local context_key = get_context_key_name(cache_filename)
  uep_context.set(context_key, data)

  unl_events.publish(unl_event_types.ON_AFTER_PROJECT_CACHE_SAVE, {
    status = "success",
    cache_filename = cache_filename,
  })

  return true, nil
end

---
-- ▼▼▼ こちらも念のため `function M.load` であることを確認 ▼▼▼
function M.load(cache_filename)
  local context_key = get_context_key_name(cache_filename)
  local cached_data = uep_context.get(context_key)
  if cached_data then
    return cached_data
  end

  local path = get_cache_path(cache_filename)
  if not path or vim.fn.filereadable(path) == 0 then
    return nil
  end

  local file_data = unl_cache_core.load_json(path)

  if not file_data or file_data.magic_code ~= MAGIC_CODE or file_data.version ~= CACHE_VERSION then
     require("UEP.logger").get().warn(
      "Project cache '%s' is outdated or invalid. It will be ignored.",
      cache_filename
    )
    return nil
  end
  
  uep_context.set(context_key, file_data)
  
  return file_data
end

function M.delete_component_cache_file(cache_filename)
  local log = require("UEP.logger").get()
  local path = get_cache_path(cache_filename)
  if not path then return false end
  
  -- 1. オンメモリキャッシュをクリア
  local context_key = get_context_key_name(cache_filename)
  require("UEP.context").del(context_key)

  -- 2. ディスク上のファイルを削除
  local stat = vim.loop.fs_stat(path)
  if stat then
    local ok, err = vim.loop.fs_unlink(path)
    if ok then
      log.info("Successfully deleted project cache: %s", path)
      return true
    else
      log.error("Failed to delete project cache %s: %s", path, tostring(err))
      return false
    end
  end
  
  return true -- ファイルが存在しない場合は成功
end

return M
