-- lua/UEP/cache/files.lua (第三世代・オンメモリキャッシュ対応・最終完成版)

local uep_config = require("UEP.config")
local unl_cache_core = require("UNL.cache.core")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local unl_path = require("UNL.path")
local uep_context = require("UEP.context") -- ★ オンメモリキャッシュ

local M = {}

local MAGIC_CODE = "UEP File Component Cache"
local CACHE_VERSION = "1.0"

M.get_name_from_root = function(root_path)
  if not root_path then return nil end
  return unl_path.normalize(root_path):gsub("[\\/:]", "_")
end

local function get_component_cache_path(component)
  if not (component and component.type and component.root_path) then return nil end
  local conf = uep_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  local files_dir = fs.joinpath(base_dir, "files")
  local component_unique_name = M.get_name_from_root(component.root_path)
  local filename
  if component.type == "Plugin" and component.owner_name then
    filename = ("%s_%s.files.json"):format(component.owner_name, component_unique_name)
  else
    filename = ("%s.files.json"):format(component_unique_name)
  end
  return fs.joinpath(files_dir, filename)
end

-- ▼▼▼ オンメモリキャッシュ対応の、新しい load / save ▼▼▼

function M.save_component_cache(component, data)
  local path = get_component_cache_path(component)
  if not path then return false end
  data.magic_code = MAGIC_CODE
  data.version = CACHE_VERSION
  local ok, err = unl_cache_core.save_json(path, data)
  if not ok then
    uep_log.get().error("Failed to save file component cache to %s: %s", path, tostring(err))
    return false
  end
  -- 保存成功後、オンメモリキャッシュも更新
  uep_context.set(path, data)
  return true
end

function M.load_component_cache(component)
  local path = get_component_cache_path(component)
  if not path then return nil end
  
  -- 1. まずオンメモリキャッシュを確認
  local cached_data = uep_context.get(path)
  if cached_data then
    return cached_data
  end

  -- 2. なければディスクから読む
  if vim.fn.filereadable(path) == 0 then return nil end
  local file_data = unl_cache_core.load_json(path)

  if not file_data or file_data.magic_code ~= MAGIC_CODE or file_data.version ~= CACHE_VERSION then
    return nil
  end
  
  -- 3. 読んだデータをオンメモリキャッシュに保存
  uep_context.set(path, file_data)
  return file_data
end

return M
