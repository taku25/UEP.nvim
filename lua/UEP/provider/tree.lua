-- lua/UEP/provider/tree.lua (コンポーネント中心構造・Rider風表示対応・完全コード)

local unl_context = require("UNL.context")
local uep_log = require("UEP.logger").get()
local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local files_cache_manager = require("UEP.cache.files")
local fs = require("vim.fs")

local M = {}

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------

local function directory_first_sorter(a, b)
  if a.type == "directory" and b.type ~= "directory" then return true
  elseif a.type ~= "directory" and b.type == "directory" then return false
  else return a.name < b.name end
end

local function build_fs_hierarchy(root_path, files, dirs)
    local dir_set = {}
    for _, dir_path in ipairs(dirs or {}) do
        dir_set[dir_path:gsub("[/\\]$", "")] = true
    end
    local all_paths = {}
    if files then vim.list_extend(all_paths, files) end
    if dirs then vim.list_extend(all_paths, dirs) end
    if #all_paths == 0 then return {} end
    local trie = {}
    for _, raw_full_path in ipairs(all_paths) do
        local full_path = raw_full_path:gsub("[/\\]$", "")
        local root_prefix = root_path:gsub("[/\\]$", "") .. "/"
        
        if full_path:sub(1, #root_prefix) == root_prefix then
            local current_level = trie
            local relative_path = full_path:sub(#root_prefix + 1)
            
            local parts = vim.split(relative_path, "[/\\]")
            for _, part in ipairs(parts) do
                if part ~= "" then
                    if not current_level[part] then current_level[part] = {} end
                    current_level = current_level[part]
                end
            end
        end
    end
    local function trie_to_nodes(sub_trie, current_path)
        local nodes = {}
        for name, content in pairs(sub_trie) do
            local new_path = fs.joinpath(current_path, name)
            local node_type = "file"
            local hierarchy = nil
            if dir_set[new_path] or next(content) then
                node_type = "directory"
                hierarchy = trie_to_nodes(content, new_path)
            end
            table.insert(nodes, {
                id = new_path, name = name, path = new_path, type = node_type,
                extra = { is_loaded = false, hierarchy = hierarchy },
            })
        end
        table.sort(nodes, directory_first_sorter)
        return nodes
    end
    return trie_to_nodes(trie, root_path)
end


local function build_final_hierarchy(components_with_files, filtered_modules_meta, game_name, engine_name)
  -- Pluginsカテゴリを削除し、GameとEngine内にplugins_nodeを追跡するフィールドを追加
  local root_categories = {
    Game = {
      id = "category_Game", name = "Game", type = "directory",
      extra = { uep_type = "category", hierarchy = {}, is_loaded = false, plugins_node = nil }
    },
    Engine = {
      id = "category_Engine", name = "Engine", type = "directory",
      extra = { uep_type = "category", hierarchy = {}, is_loaded = false, plugins_node = nil }
    },
  }

  for _, component in ipairs(components_with_files) do
    local component_node = {
      id = component.root_path, name = component.display_name, path = component.root_path,
      type = "directory",
      extra = { uep_type = component.type, hierarchy = {}, is_loaded = false },
    }
    
    local category_base_path = component.root_path
    if component.type == "Engine" then category_base_path = fs.joinpath(component.root_path, "Engine") end
    
    local categories = {
      Source = { files = component.files.source, dirs = component.dirs.source, root = fs.joinpath(category_base_path, "Source") },
      Config = { files = component.files.config, dirs = component.dirs.config, root = fs.joinpath(category_base_path, "Config") },
      Shaders = { files = component.files.shader, dirs = component.dirs.shader, root = fs.joinpath(category_base_path, "Shaders") },
      Programs = { files = component.files.programs, dirs = component.dirs.programs, root = fs.joinpath(category_base_path, "Programs") },
    }
    
    for name, data in pairs(categories) do
      local files_to_render = {}
      local dirs_to_render = {}

      if name == "Source" then
        local paths_to_include = {}
        for mod_name, mod_meta in pairs(filtered_modules_meta or {}) do
          if mod_meta.module_root and mod_meta.module_root:find(component.root_path, 1, true) then
            table.insert(paths_to_include, mod_meta.module_root)
          end
        end
        if component.type == "Engine" then
          local programs_root = fs.joinpath(data.root, "Programs")
          table.insert(paths_to_include, programs_root)
        end

        local candidate_files = vim.list_extend(vim.deepcopy(data.files or {}), component.files.programs or {})
        local candidate_dirs = vim.list_extend(vim.deepcopy(data.dirs or {}), component.dirs.programs or {})

        for _, file in ipairs(candidate_files) do
          for _, include_path in ipairs(paths_to_include) do
            if file:find(include_path, 1, true) then
              table.insert(files_to_render, file)
              break
            end
          end
        end
        for _, dir in ipairs(candidate_dirs) do
          for _, include_path in ipairs(paths_to_include) do
            if dir:find(include_path, 1, true) then
              table.insert(dirs_to_render, dir)
              break
            end
          end
        end
      else
        files_to_render = data.files or {}
        dirs_to_render = data.dirs or {}
      end
      
      if #files_to_render > 0 or #dirs_to_render > 0 then
        local category_node = {
          id = data.root, name = name, path = data.root, type = "directory",
          extra = { uep_type = "category_in_component", is_loaded = false, hierarchy = build_fs_hierarchy(data.root, files_to_render, dirs_to_render) },
        }
        table.insert(component_node.extra.hierarchy, category_node)
      end
    end
    
    local root_file_categories = { uproject = "uproject", uplugin = "uplugin" }
    for cat_name, uep_type in pairs(root_file_categories) do
      if component.files[cat_name] and #component.files[cat_name] > 0 then
        for _, file_path in ipairs(component.files[cat_name]) do
          local file_name = vim.fn.fnamemodify(file_path, ":t")
          table.insert(component_node.extra.hierarchy, {
            id = file_path, name = file_name, path = file_path, type = "file",
            extra = { uep_type = uep_type },
          })
        end
      end
    end

    if #component_node.extra.hierarchy > 0 then
      table.sort(component_node.extra.hierarchy, directory_first_sorter)

      if component.type == "Game" then
        table.insert(root_categories.Game.extra.hierarchy, component_node)
      elseif component.type == "Engine" then
        table.insert(root_categories.Engine.extra.hierarchy, component_node)
      elseif component.type == "Plugin" then
        local owner_category
        if component.owner_name == game_name then
          owner_category = root_categories.Game
        elseif component.owner_name == engine_name then
          owner_category = root_categories.Engine
        end

        if owner_category then
          if not owner_category.extra.plugins_node then
            local plugins_node_path = fs.joinpath(owner_category.id, "Plugins")
            owner_category.extra.plugins_node = {
              id = plugins_node_path, name = "Plugins", path = plugins_node_path,
              type = "directory",
              extra = { uep_type = "category", hierarchy = {}, is_loaded = false },
            }
            table.insert(owner_category.extra.hierarchy, owner_category.extra.plugins_node)
          end
          table.insert(owner_category.extra.plugins_node.extra.hierarchy, component_node)
        end
      end
    end
  end
  
  local final_nodes = {}
  for _, category_name in ipairs({ "Game", "Engine" }) do
    local category_node = root_categories[category_name]
    if category_node.extra.plugins_node then
      table.sort(category_node.extra.plugins_node.extra.hierarchy, directory_first_sorter)
    end
    if #category_node.extra.hierarchy > 0 then
      table.sort(category_node.extra.hierarchy, directory_first_sorter)
      table.insert(final_nodes, category_node)
    end
  end
  return final_nodes
end

-------------------------------------------------
-- プロバイダー公開関数
-------------------------------------------------
function M.get_pending_tree_request(opts)
  local consumer_id = (opts and opts.consumer) or "unknown"
  local handle = unl_context.use("UEP"):key("pending_request:" .. consumer_id)
  local payload = handle:get("payload")
  if payload then handle:del("payload"); return payload end
  return nil
end

function M.build_tree_model(opts)
  local request_payload = M.get_pending_tree_request({ consumer = "neo-tree-uproject" }) or {}
  opts = vim.tbl_deep_extend("force", opts or {}, request_payload)
  local project_root = opts.project_root
  if not project_root then return nil end

  -- STEP 1 & 2: 必要なモジュールとコンポーネントを特定
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then
    return {{ id = "_message_", name = "Project not found in registry. Run :UEP refresh.", type = "message" }}
  end
  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache then
      all_components_map[comp_name] = p_cache
      if p_cache.modules then
        for mod_name, mod_data in pairs(p_cache.modules) do
          all_modules_map[mod_name] = mod_data
          module_to_component_name[mod_name] = comp_name
        end
      end
    end
  end
  if not next(all_modules_map) then return nil end
  
  -- プラグインの所属判定に使うため、GameとEngineのユニーク名を取得する
  local game_name, engine_name
  for name, comp in pairs(all_components_map) do
      if comp.type == "Game" then game_name = name end
      if comp.type == "Engine" then engine_name = name end
  end
  if not game_name or not engine_name then
      return {{ id = "_message_", name = "Game/Engine component not found in cache.", type = "message" }}
  end

  local target_module_names = {}
  if opts.target_module then
    target_module_names[opts.target_module] = true
    local start_module = all_modules_map[opts.target_module]
    if start_module then
      local deps_key = opts.all_deps and "deep_dependencies" or "shallow_dependencies"
      for _, dep_name in ipairs(start_module[deps_key] or {}) do
        target_module_names[dep_name] = true
      end
    end
  else
    for name, meta in pairs(all_modules_map) do
      if meta.category == "Game" then
        target_module_names[name] = true
        local deps_key = opts.all_deps and "deep_dependencies" or "shallow_dependencies"
        for _, dep_name in ipairs(meta[deps_key] or {}) do
          target_module_names[dep_name] = true
        end
      end
    end
  end
  
  local filtered_modules_meta = {}
  for name, _ in pairs(target_module_names) do
    if all_modules_map[name] then
      filtered_modules_meta[name] = all_modules_map[name]
    end
  end

  -- STEP 3: 表示対象となるコンポーネントを特定
  local required_components_map = {}
  for mod_name, _ in pairs(filtered_modules_meta) do
    local comp_name = module_to_component_name[mod_name]
    if comp_name and not required_components_map[comp_name] then
      required_components_map[comp_name] = all_components_map[comp_name]
    end
  end

  -- STEP 4: 各コンポーネントに属するファイルを集計
  local components_with_files = {}
  for comp_name, component_meta in pairs(required_components_map) do
    local files_cache = files_cache_manager.load_component_cache(component_meta)
    if files_cache then
      component_meta.display_name = component_meta.display_name or comp_name
      component_meta.files = files_cache.files or {}
      component_meta.dirs = files_cache.directories or {}
      
      for _, cat in ipairs({ "source", "config", "shader", "programs", "content", "other" }) do
        component_meta.files[cat] = component_meta.files[cat] or {}
        component_meta.dirs[cat] = component_meta.dirs[cat] or {}
      end
      
      table.insert(components_with_files, component_meta)
    end
  end

  -- STEP 5: 準備したデータを使って、新しいコンポーネント中心のツリー構造を構築
  local hierarchy = build_final_hierarchy(components_with_files, filtered_modules_meta, game_name, engine_name)
 
  if not next(hierarchy) then
    return {{ id = "_message_", name = "No components to display with current filters.", type = "message" }}
  end
  
  -- STEP 6: 最終的なルートノードを返す
  return {{
    id = "logical_root",
    name = project_registry_info.display_name or "Logical View", -- プロジェクト名をルートに
    path = project_root,
    type = "directory",
    extra = { uep_type = "project_root", hierarchy = hierarchy, is_loaded = false },
  }}
end

function M.request(opts)
  if opts and opts.capability == "uep.get_pending_tree_request" then
    return M.get_pending_tree_request(opts)
  elseif opts and opts.capability == "uep.build_tree_model" then
    return M.build_tree_model(opts)
  else
    uep_log.warn("Unknown request to UEP tree provider: %s", vim.inspect(opts))
    return nil
  end
end

return M
