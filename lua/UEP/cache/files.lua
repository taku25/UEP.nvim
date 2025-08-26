-- lua/UEP/cache/files.lua (コンテキストキャッシュ対応版)

local uep_config = require("UEP.config")
local unl_cache_core = require("UNL.cache.core")
local uep_log = require("UEP.logger")
local unl_path = require("UNL.path")
local fs = require("vim.fs")
local uep_context = require("UEP.context") --- ★ 変更点: contextモジュールをrequire

local M = {}

local function project_root_to_filename(project_root)
  if not project_root or type(project_root) ~= "string" then
    uep_log.get().error("Invalid project_root provided: %s", tostring(project_root))
    return nil
  end
  local normalized_path = unl_path.normalize(project_root)
  return normalized_path:gsub("[\\/:]", "_") .. ".json"
end

local function get_cache_path(project_root)
  local conf = uep_config.get(project_root)
  local base_dir = unl_cache_core.get_cache_dir(conf)
  local files_dir = fs.joinpath(base_dir, "files")
  local filename = project_root_to_filename(project_root)
  if not filename then return nil end
  return fs.joinpath(files_dir, filename)
end

--- コンテキストキャッシュで使うための一意なキー名を取得
local function get_context_key_name(root_path)
  return get_cache_path(root_path) .. "::files" -- 他と区別するためサフィックスを追加
end

function M.save(project_root, data)
  local path = get_cache_path(project_root)
  if not path then
    uep_log.get().error("Could not generate cache path for save operation. Aborting.")
    return false
  end

  -- 1. ファイルに保存
  local ok, err = unl_cache_core.save_json(path, data)
  if not ok then
    uep_log.get().error("Failed to save files.json: %s", tostring(err))
  end

  --- ★ 変更点: 保存成功後、コンテキストキャッシュも更新する
  if ok then
    local context_key = get_context_key_name(project_root)
    uep_context.set(context_key, data)
  end

  return ok
end

function M.load(project_root)
  --- ★ 変更点: まずコンテキストキャッシュを確認
  local context_key = get_context_key_name(project_root)
  local cached_data = uep_context.get(context_key)
  if cached_data then
    -- コンテキストにデータがあれば、それを返す
    return cached_data
  end

  -- コンテキストになければ、ファイルから読み込む
  local path = get_cache_path(project_root)
  if not path or vim.fn.filereadable(path) == 0 then return nil end

  local file_data = unl_cache_core.load_json(path)

  --- ★ 変更点: ファイルから読み込んだデータをコンテキストに保存する
  if file_data then
    uep_context.set(context_key, file_data)
  end

  return file_data
end

return M
