-- lua/UEP/cmd/files_core.lua (単一モジュール取得関数を追加)

local unl_finder = require("UNL.finder")
local project_cache = require("UEP.cache.project")
local files_cache_manager = require("UEP.cache.files")
local projects_cache = require("UEP.cache.projects")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

function M.get_project_maps(start_path, on_complete)
  local project_root = unl_finder.project.find_project_root(start_path)
  if not project_root then
    return on_complete(false, "Could not find project root.")
  end
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then
    return on_complete(false, "Project not found in registry. Please run :UEP refresh.")
  end

  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache then
      all_components_map[comp_name] = p_cache
      for mod_name, mod_data in pairs(p_cache.modules or {}) do
        all_modules_map[mod_name] = mod_data
        module_to_component_name[mod_name] = comp_name
      end
    end
  end
  
  on_complete(true, {
    project_root = project_root,
    all_modules_map = all_modules_map,
    module_to_component_name = module_to_component_name,
    all_components_map = all_components_map,
    project_registry_info = project_registry_info,
  })
end
-- 内部ヘルパー: プロジェクトの基本情報を読み込む（複数箇所で再利用）
local function get_project_maps(start_path, on_complete)
  local project_root = unl_finder.project.find_project_root(start_path)
  if not project_root then
    return on_complete(false, "Could not find project root.")
  end
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then
    return on_complete(false, "Project not found in registry. Please run :UEP refresh.")
  end

  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache then
      all_components_map[comp_name] = p_cache
      for mod_name, mod_data in pairs(p_cache.modules or {}) do
        all_modules_map[mod_name] = mod_data
        module_to_component_name[mod_name] = comp_name
      end
    end
  end
  
  on_complete(true, {
    project_root = project_root,
    all_modules_map = all_modules_map,
    module_to_component_name = module_to_component_name,
    all_components_map = all_components_map,
    project_registry_info = project_registry_info,
  })
end


function M.get_merged_files_for_project(start_path, opts, on_complete)
  -- (この関数に変更はありません)
  opts = opts or {}
  local log = uep_log.get()

  get_project_maps(start_path, function(ok, maps)
    if not ok then return on_complete(false, maps) end
    
    local all_modules_map = maps.all_modules_map
    local module_to_component_name = maps.module_to_component_name
    local all_components_map = maps.all_components_map

    local required_modules_set = {}
    local root_component = nil
    for _, component in pairs(all_components_map) do
      if component.type == opts.scope then
        root_component = component
        break
      end
    end
    
    if root_component and root_component.modules then
      for mod_name, _ in pairs(root_component.modules) do
        required_modules_set[mod_name] = true
        local mod_data = all_modules_map[mod_name]
        if mod_data then
          local deps_key = (opts.deps_flag == "--all-deps") and "deep_dependencies" or "shallow_dependencies"
          for _, dep_name in ipairs(mod_data[deps_key] or {}) do
            required_modules_set[dep_name] = true
          end
        end
      end
    end

    local components_to_scan = {}
    for mod_name, _ in pairs(required_modules_set) do
      local comp_name = module_to_component_name[mod_name]
      if comp_name and not components_to_scan[comp_name] then
        components_to_scan[comp_name] = all_components_map[comp_name]
      end
    end

    local required_module_roots = {}
    for mod_name, _ in pairs(required_modules_set) do
        if all_modules_map[mod_name] and all_modules_map[mod_name].module_root then
            table.insert(required_module_roots, all_modules_map[mod_name].module_root)
        end
    end
    table.sort(required_module_roots, function(a, b) return #a > #b end)

    local merged_data = {
      files = { source={}, config={}, shader={}, content={}, programs={}, other={} },
      dirs = { source={}, config={}, shader={}, content={}, programs={}, other={} },
      header_details = {}
    }

    for _, component in pairs(components_to_scan) do
      local component_cache = files_cache_manager.load_component_cache(component)
      if component_cache then
        for category, file_list in pairs(component_cache.files or {}) do
          for _, file_path in ipairs(file_list) do
            for _, module_root in ipairs(required_module_roots) do
              if file_path:find(module_root, 1, true) then
                table.insert(merged_data.files[category], file_path)
                break
              end
            end
          end
        end
        for category, dir_list in pairs(component_cache.directories or {}) do
          for _, dir_path in ipairs(dir_list) do
            for _, module_root in ipairs(required_module_roots) do
              if dir_path:find(module_root, 1, true) then
                table.insert(merged_data.dirs[category], dir_path)
                break
              end
            end
          end
        end
        if component_cache.header_details then
          for file_path, details in pairs(component_cache.header_details) do
             for _, module_root in ipairs(required_module_roots) do
              if file_path:find(module_root, 1, true) then
                merged_data.header_details[file_path] = details
                break
              end
            end
          end
        end
      end
    end
    on_complete(true, merged_data)
  end)
end

-- ▼▼▼ 新しく追加した関数 ▼▼▼
function M.get_files_for_single_module(start_path, module_name, on_complete)
  get_project_maps(start_path, function(ok, maps)
    if not ok then return on_complete(false, maps) end
    
    local module_data = maps.all_modules_map[module_name]
    if not module_data or not module_data.module_root then
      return on_complete(false, ("Module '%s' or its root path not found."):format(module_name))
    end
    local module_root = module_data.module_root
    
    local component_name = maps.module_to_component_name[module_name]
    if not component_name then
      return on_complete(false, ("Component for module '%s' not found."):format(module_name))
    end
    
    local component = maps.all_components_map[component_name]
    local component_cache = files_cache_manager.load_component_cache(component)
    if not component_cache then
      return on_complete(true, {}) -- ファイルが見つからなかった（正常系）
    end

    local module_files = {}
    for _, file_list in pairs(component_cache.files or {}) do
      for _, file_path in ipairs(file_list) do
        if file_path:find(module_root, 1, true) then
          table.insert(module_files, file_path)
        end
      end
    end
    on_complete(true, module_files)
  end)
end
-- ▲▲▲ ここまで ▲▲▲


return M
