-- lua/UEP/cache/projects.lua (第三世代・究極のマスターインデックス・最終完成版)

local unl_cache_core = require("UNL.cache.core")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local fs = require("vim.fs")
local unl_path = require("UNL.path")

local M = {}

local MAGIC_CODE = "UEP Master Project Registry"
local REGISTRY_VERSION = 2 -- 構造変更のためバージョンアップ
local CACHE_FILENAME = "projects.json"

local function get_name_from_root(root_path)
  if not root_path then return nil end
  return unl_path.normalize(root_path):gsub("[\\/:]", "_")
end

local function get_cache_path()
  local conf = uep_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  return fs.joinpath(base_dir, CACHE_FILENAME)
end

function M.load()
  local path = get_cache_path()
  if vim.fn.filereadable(path) == 0 then
    return { magic_code = MAGIC_CODE, version = REGISTRY_VERSION, projects = {}, engines = {} }
  end
  
  local data = unl_cache_core.load_json(path)
  if not data or data.magic_code ~= MAGIC_CODE or data.version ~= REGISTRY_VERSION then
    require("UEP.logger").get().warn("Project registry is outdated or invalid. Creating a new one.")
    return { magic_code = MAGIC_CODE, version = REGISTRY_VERSION, projects = {}, engines = {} }
  end

  data.projects = data.projects or {}
  data.engines = data.engines or {}
  return data
end

function M.save(registry_data)
  registry_data.magic_code = MAGIC_CODE
  registry_data.version = REGISTRY_VERSION

  local path = get_cache_path()
  local ok, err = unl_cache_core.save_json(path, registry_data)
  if not ok then
    require("UEP.logger").get().error("Failed to save master project registry: %s", tostring(err))
  end
  
  if ok then
    unl_events.publish(unl_event_types.ON_AFTER_PROJECTS_CACHE_SAVE, { status = "success" })
  end
  return ok
end

--- 新しい高レベルAPI: プロジェクトとその全コンポーネントを登録する
function M.register_project_with_components(registration_info, all_components)
  local registry = M.load()
  local project_display_name = vim.fn.fnamemodify(registration_info.root_path, ":t")
  local project_name = get_name_from_root(registration_info.root_path)
  local engine_name = get_name_from_root(registration_info.engine_root)
  
  local component_names = {}
  for _, comp in ipairs(all_components) do
    table.insert(component_names, comp.name)
  end

  registry.projects[project_display_name] = {
    unique_name = project_name,
    uproject_path = registration_info.uproject_path,
    project_cache_filename = project_name .. ".project.json",
    engine_association = engine_name,
    last_indexed_at = os.time(),
    components = component_names, -- ★★★
  }

  registry.engines[engine_name] = {
    engine_root = registration_info.engine_root,
    project_cache_filename = engine_name .. ".project.json",
  }
  
  return M.save(registry)
end

function M.get_project_info(project_display_name)
  local registry = M.load()
  return registry.projects and registry.projects[project_display_name]
end

function M.get_engine_info(engine_name)
  local registry = M.load()
  return registry.engines and registry.engines[engine_name]
end

function M.remove_project(project_display_name)
  local registry = M.load()
  if registry.projects and registry.projects[project_display_name] then
    registry.projects[project_display_name] = nil
    return M.save(registry)
  end
  return true
end

return M
