-- lua/UEP/cache/project.lua (コンテキストキャッシュ対応版)

local uep_config = require("UEP.config")
local unl_cache_core = require("UNL.cache.core")
local unl_path = require("UNL.path")
local fs = require("vim.fs")
local uep_context = require("UEP.context") --- ★ 変更点: contextモジュールをrequire

local M = {}

local function root_to_filename(root_path)
  local normalized_path = unl_path.normalize(root_path)
  return normalized_path:gsub("[\\/:]", "_") .. ".json"
end

local function get_cache_path(root_path)
  local conf = uep_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  local projects_dir = fs.joinpath(base_dir, "projects")
  local filename = root_to_filename(root_path)
  return fs.joinpath(projects_dir, filename)
end

--- コンテキストキャッシュで使うための一意なキー名を取得
local function get_context_key_name(root_path)
  return get_cache_path(root_path) .. "::project" -- 他と区別するためサフィックスを追加
end

function M.exists(root_path)
  if not root_path then return false end
  return vim.fn.filereadable(get_cache_path(root_path)) == 1
end

--- キャッシュを保存する
function M.save(root_path, type, data)
  local path = get_cache_path(root_path)
  data.Type = type
  data.root = root_path

  -- 1. ファイルに保存する
  local ok, err = unl_cache_core.save_json(path, data)
  if not ok then
    return false, require("UEP.logger").get().error("Failed to save projects.json: %s", tostring(err))
  end

  --- ★ 変更点: 保存成功後、コンテキストキャッシュも更新する
  local context_key = get_context_key_name(root_path)
  uep_context.set(context_key, data)

  return ok, nil
end

--- キャッシュを読み込む
function M.load(root_path)
  --- ★ 変更点: まずコンテキストキャッシュを確認
  local context_key = get_context_key_name(root_path)
  local cached_data = uep_context.get(context_key)
  if cached_data then
    -- コンテキストにデータがあれば、それを返す
    return cached_data
  end

  -- コンテキストになければ、ファイルから読み込む
  local path = get_cache_path(root_path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local file_data = unl_cache_core.load_json(path)

  --- ★ 変更点: ファイルから読み込んだデータをコンテキストに保存する
  if file_data then
    uep_context.set(context_key, file_data)
  end

  return file_data
end

return M
