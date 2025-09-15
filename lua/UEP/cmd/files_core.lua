-- lua/UEP/cmd/files_core.lua (第三世代・究極の組立工場・最終完成版)

local unl_finder = require("UNL.finder")
local project_cache = require("UEP.cache.project")
local files_cache_manager = require("UEP.cache.files")
local projects_cache = require("UEP.cache.projects") -- ★マスターインデックス
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

function M.get_merged_files_for_project(start_path, opts, on_complete)
  opts = opts or {}
  local log = uep_log.get()

  -- STEP 1: マスターインデックスから、プロジェクトの全コンポーネントリストを取得
  local project_root = unl_finder.project.find_project_root(start_path)
  if not project_root then
    return on_complete(false, "Could not find project root.")
  end
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then
    return on_complete(false, "Project not found in registry. Please run :UEP refresh.")
  end
  local all_component_names = project_registry_info.components

  -- STEP 2: 全コンポーネントの「設計図」を読み込み、巨大なモジュールマップを構築
  log.info("Building dependency map from %d components...", #all_component_names)
  local all_modules_map = {}
  local module_to_component_name = {}
  local all_components_map = {}

  for _, comp_name in ipairs(all_component_names) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache then
      all_components_map[comp_name] = p_cache
      for mod_name, mod_data in pairs(p_cache.modules or {}) do
        all_modules_map[mod_name] = mod_data
        module_to_component_name[mod_name] = comp_name
      end
    end
  end

  -- STEP 3: ユーザーの指示に基づき、「本当に必要なモジュール」のセットを計算
  local required_modules_set = {}
  local game_component = all_components_map[project_registry_info.unique_name]
  if game_component and game_component.modules then
    for mod_name, _ in pairs(game_component.modules) do
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

  -- STEP 4: 「本当に必要なコンポーネント」のセットを計算 (バグ修正済み)
  local required_components = {}
  if game_component then
      required_components[game_component.name] = game_component
  end
  for mod_name, _ in pairs(required_modules_set) do
    local comp_name = module_to_component_name[mod_name]
    if comp_name and not required_components[comp_name] then
      required_components[comp_name] = all_components_map[comp_name]
    end
  end

  -- STEP 5: 「本当に必要なコンポーネント」の.files.jsonだけを読み込み、マージ
  log.info("Found %d required components. Merging file caches...", vim.tbl_count(required_components))
  local merged_data = {
    files = { source={}, config={}, shader={}, content={}, programs={}, other={} },
    dirs = { source={}, config={}, shader={}, content={}, programs={}, other={} },
    header_details = {}
  }

  for _, component in pairs(required_components) do
    local component_info_for_load = { type = component.type, root_path = component.root_path, owner_name = component.owner_name, short_name = component.display_name }
    local component_cache = files_cache_manager.load_component_cache(component_info_for_load)
    if component_cache then
      for category, file_list in pairs(component_cache.files or {}) do
        if merged_data.files[category] then vim.list_extend(merged_data.files[category], file_list) end
      end
      for category, dir_list in pairs(component_cache.directories or {}) do
        if merged_data.dirs[category] then vim.list_extend(merged_data.dirs[category], dir_list) end
      end
      if component_cache.header_details then
        vim.tbl_deep_extend("force", merged_data.header_details, component_cache.header_details)
      end
    end
  end
  
  on_complete(true, merged_data)
end

return M
