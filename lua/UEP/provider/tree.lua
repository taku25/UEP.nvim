-- lua/UEP/provider/tree.lua
-- (ユニークID受け渡し修正版)

local unl_context = require("UNL.context")
local uep_log = require("UEP.logger") 
local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local module_cache = require("UEP.cache.module")
local fs = require("vim.fs")
local uep_context = require("UEP.context")

local M = {}

local EXPANDED_STATE_KEY = "tree_expanded_state"

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------

local function directory_first_sorter(a, b)
  if a.type == "directory" and b.type ~= "directory" then return true
  elseif a.type ~= "directory" and b.type == "directory" then return false
  else return a.name < b.name end
end

local function build_fs_hierarchy(root_path, aggregated_files, aggregated_dirs, is_eager)
    local log = uep_log.get()
    
    local nodes = {}
    local direct_children_map = {} 
    local grand_children_exist = {} 

    local root_prefix = root_path:gsub("[/\\]$", "") .. "/"
    local root_prefix_lower = root_prefix:lower()
    local root_prefix_len = #root_prefix

    local expanded_nodes = uep_context.get(EXPANDED_STATE_KEY) or {}

    local function process_paths(paths, item_type)
        for _, raw_full_path in ipairs(paths or {}) do
            local full_path_lower = raw_full_path:lower()
            if full_path_lower:sub(1, root_prefix_len) == root_prefix_lower then
                local relative_path = raw_full_path:sub(root_prefix_len + 1)
                if relative_path ~= "" then
                  local separator_pos = relative_path:find("[/\\]")
                  if separator_pos then
                      local first_part = relative_path:sub(1, separator_pos - 1)
                      if not direct_children_map[first_part] then
                          direct_children_map[first_part] = "directory"
                      end
                      grand_children_exist[first_part] = true
                  else
                      if not direct_children_map[relative_path] then
                         direct_children_map[relative_path] = item_type
                      end
                  end
                end
            end
        end
    end

    process_paths(aggregated_dirs, "directory")
    process_paths(aggregated_files, "file")

    for name, node_type in pairs(direct_children_map) do
        local child_path = fs.joinpath(root_path, name)
        local has_children = (node_type == "directory" and grand_children_exist[name])
        
        local node_data = {
            id = child_path,
            name = name,
            path = child_path,
            type = node_type,
            children = has_children and {} or nil,
            loaded = not has_children, 
            extra = {
                uep_type = "fs",
                child_paths = { files = aggregated_files, dirs = aggregated_dirs }
            }
        }
        
        if has_children and (is_eager or expanded_nodes[child_path]) then
            node_data.loaded = true
            node_data.children = build_fs_hierarchy(child_path, aggregated_files, aggregated_dirs, is_eager)
        end
        table.insert(nodes, node_data)
    end
    table.sort(nodes, directory_first_sorter)
    return nodes
end

-- ▼▼▼ 修正: 引数に owner_name (ユニークID) を追加 ▼▼▼
local function build_top_level_nodes(required_components_map, filtered_modules_meta, game_name, engine_name, game_owner, engine_owner, project_root, engine_root)
    local top_nodes = {}
    local log = uep_log.get()
    
    local expanded_nodes = uep_context.get(EXPANDED_STATE_KEY) or {}
    
    local game_node = {
        id = "category_Game", name = game_name, path = project_root, type = "directory",
        children = {}, loaded = false,
        extra = {
            uep_type = "category",
            child_context = { 
                type = "GameRoot", 
                root = project_root, 
                engine_root = engine_root, 
                
                -- ★修正: IDも渡す
                game_name = game_name, 
                game_owner = game_owner, 
                
                engine_name = engine_name, 
                engine_owner = engine_owner,
                
                required_components_map = required_components_map, 
                filtered_modules_meta = filtered_modules_meta 
            }
        }
    }
    if expanded_nodes[game_node.id] then
        game_node.loaded = true
        game_node.children = M.load_children(game_node)
    end
    table.insert(top_nodes, game_node)

    local engine_node = {
        id = "category_Engine", name = "Engine", path = engine_root, type = "directory",
        children = {}, loaded = false,
        extra = {
            uep_type = "category",
            child_context = { 
                type = "EngineRoot", 
                root = engine_root, 
                
                -- ★修正: IDも渡す
                game_name = game_name, 
                game_owner = game_owner,
                
                engine_name = engine_name, 
                engine_owner = engine_owner,
                
                required_components_map = required_components_map, 
                filtered_modules_meta = filtered_modules_meta 
            }
        }
    }
    if expanded_nodes[engine_node.id] then
        engine_node.loaded = true
        engine_node.children = M.load_children(engine_node)
    end
    table.insert(top_nodes, engine_node)

    table.sort(top_nodes, directory_first_sorter)
    return top_nodes
end
-- ▲▲▲ 修正完了 ▲▲▲

local function build_module_nodes(filtered_modules_meta)
    local log = uep_log.get()
    local top_nodes = {}
    
    for mod_name, mod_meta in pairs(filtered_modules_meta) do
        local mod_cache_data = module_cache.load(mod_meta)
        local source_files = {}
        local source_dirs = {}
        if mod_cache_data then
            if mod_cache_data.files then
                for cat, files in pairs(mod_cache_data.files) do
                    if cat ~= "programs" then
                        vim.list_extend(source_files, files)
                    end
                end
            end
            if mod_cache_data.directories then
                for cat, dirs in pairs(mod_cache_data.directories) do
                    if cat ~= "programs" then
                        vim.list_extend(source_dirs, dirs)
                    end
                end
            end
        end

        local children_nodes = build_fs_hierarchy(mod_meta.module_root, source_files, source_dirs, true) 

        local node_data = {
            id = "module_root_" .. mod_name,
            name = mod_name,
            path = mod_meta.module_root,
            type = "directory",
            children = children_nodes,
            loaded = true, 
            extra = {
                uep_type = "module_root",
                mod_meta = mod_meta 
            }
        }
        table.insert(top_nodes, node_data)
    end
    
    table.sort(top_nodes, directory_first_sorter)
    return top_nodes
end

-------------------------------------------------
-- プロバイダー公開関数
-------------------------------------------------

function M.clear_tree_state()
    local log = uep_log.get()
    uep_context.del(EXPANDED_STATE_KEY)
    return true
end

function M.get_pending_tree_request(opts)
  local consumer_id = (opts and opts.consumer) or "unknown"
  local handle = unl_context.use("UEP"):key("pending_request:" .. consumer_id)
  local payload = handle:get("payload")
  if payload then handle:del("payload"); return payload end
  return nil
end

function M.build_tree_model(opts)
  local log = uep_log.get()
  
  local request_payload = M.get_pending_tree_request({ consumer = "neo-tree-uproject" }) or {} 
  opts = vim.tbl_deep_extend("force", opts or {}, request_payload)
  
  local project_root = opts.project_root
  local engine_root = opts.engine_root
  if not project_root then return nil end
  
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then
    return {{ id = "_message_", name = "Project not registered.", type = "message" }}
  end
  
  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  local game_name, engine_name
  
  -- ▼▼▼ 修正: owner_name (ユニークID) も取得する変数を追加 ▼▼▼
  local game_owner, engine_owner
  
  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache then
      all_components_map[comp_name] = p_cache
      p_cache.uproject_path = (p_cache.type == "Game" and project_registry_info.uproject_path) or nil
      for _, module_type in ipairs({ "runtime_modules", "developer_modules", "editor_modules", "programs_modules" }) do
        if p_cache[module_type] then
          for mod_name, mod_data in pairs(p_cache[module_type]) do
            all_modules_map[mod_name] = mod_data
            module_to_component_name[mod_name] = comp_name
          end
        end
      end
      
      -- ★修正: ここで owner_name も取得して保持する
      if p_cache.type == "Game" then 
          game_name = p_cache.display_name
          game_owner = p_cache.owner_name -- これが重要！
      end
      if p_cache.type == "Engine" then 
          engine_name = p_cache.display_name
          engine_owner = p_cache.owner_name -- これが重要！
      end
    end
  end
  -- ▲▲▲ 修正完了 ▲▲▲
  
  if not next(all_modules_map) then return {{ id = "_message_", name = "No modules in cache.", type = "message" }} end
  
  local target_module_names = {}
  local requested_scope = (opts.scope and opts.scope:lower()) or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"
  
  local seed_modules = {}
  if opts.target_module then
    if all_modules_map[opts.target_module] then
        seed_modules[opts.target_module] = true
    else
        return {{ id = "_message_", name = "Module not found: " .. opts.target_module, type = "message" }}
    end
  else
    if requested_scope == "game" then for n, m in pairs(all_modules_map) do if m.owner_name == game_name then seed_modules[n] = true end end
    elseif requested_scope == "engine" then for n, m in pairs(all_modules_map) do if m.owner_name == engine_name then seed_modules[n] = true end end
    elseif requested_scope == "runtime" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
    elseif requested_scope == "developer" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
    elseif requested_scope == "editor" then for n, m in pairs(all_modules_map) do if m.type and m.type ~= "Program" then local ct = m.type:match("^%s*(.-)%s*$"):lower(); if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then seed_modules[n] = true end end end
    elseif requested_scope == "full" then for n,_ in pairs(all_modules_map) do seed_modules[n] = true end
    else requested_scope = "runtime"; for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
  end
  end
  
  target_module_names = seed_modules 

  if deps_flag ~= "--no-deps" and not opts.target_module then
    local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
    
    for mod_name, _ in pairs(seed_modules) do
        local mod_meta = all_modules_map[mod_name]
        if mod_meta and mod_meta[deps_key] then
            for _, dep_name in ipairs(mod_meta[deps_key]) do
                local dep_meta = all_modules_map[dep_name]
                if dep_meta then
                    local should_add = false
                    if requested_scope == "game" or requested_scope == "engine" or requested_scope == "editor" or requested_scope == "full" then
                        if dep_meta.type and dep_meta.type ~= "Program" then should_add = true end
                    elseif requested_scope == "runtime" then
                        should_add = (dep_meta.type == "Runtime")
                    elseif requested_scope == "developer" then
                        should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer")
                    end
                    if should_add then target_module_names[dep_name] = true end
                end
            end
        end
    end
  end
      
  local filtered_modules_meta = {}; for name, _ in pairs(target_module_names) do if all_modules_map[name] then filtered_modules_meta[name] = all_modules_map[name] end end

  local required_components_map = {}; for mod_name, _ in pairs(filtered_modules_meta) do local comp_name = module_to_component_name[mod_name]; if comp_name and not required_components_map[comp_name] then required_components_map[comp_name] = all_components_map[comp_name] end end

  local top_level_nodes
  if opts.target_module then
      top_level_nodes = build_module_nodes(filtered_modules_meta)
  else
      -- ★修正: 引数に game_owner, engine_owner を追加
      top_level_nodes = build_top_level_nodes(required_components_map, filtered_modules_meta, game_name, engine_name, game_owner, engine_owner, project_root, engine_root)
  end
  
  if not next(top_level_nodes) then
    return {{ id = "_message_", name = "No components/files to display.", type = "message" }}
  end

  return {{
    id = "logical_root",
    name = project_display_name or "Logical View",
    path = project_root, type = "directory",
    loaded = true,
    children = top_level_nodes, 
    extra = { uep_type = "project_root" },
  }}
end


function M.load_children(node)
    if node and node.id then
        local expanded_nodes = uep_context.get(EXPANDED_STATE_KEY) or {}
        expanded_nodes[node.id] = true
        uep_context.set(EXPANDED_STATE_KEY, expanded_nodes)
    end
    
    local log = uep_log.get() 
    local expanded_nodes = uep_context.get(EXPANDED_STATE_KEY) or {}

    if not node or not node.extra then return {} end

    local children = {}
    local uep_type = node.extra.uep_type
    
    if uep_type == "category" or uep_type == "Game" or uep_type == "Engine" or uep_type == "Plugin" then
        local context = node.extra.child_context
        if context then
            local required_components_map = context.required_components_map
            local filtered_modules_meta = context.filtered_modules_meta
            
            -- ▼▼▼ 修正: 渡されたユニークID (owner) を直接使う ▼▼▼
            local owner_name_to_match = (context.type == "GameRoot") and context.game_owner or context.engine_owner
            -- ▲▲▲ 修正完了 ▲▲▲

            local child_files = {} 
            local child_dirs = {}
            
            local pseudo_module_files = {}
            if context.type == "GameRoot" then
              pseudo_module_files._GameShaders = { root=fs.joinpath(context.root, "Shaders"), files={}, dirs={} }
              pseudo_module_files._GameConfig  = { root=fs.joinpath(context.root, "Config"), files={}, dirs={} }
            else 
              pseudo_module_files._EngineShaders = { root=fs.joinpath(context.root, "Engine", "Shaders"), files={}, dirs={} }
              pseudo_module_files._EngineConfig  = { root=fs.joinpath(context.root, "Engine", "Config"), files={}, dirs={} }
            end
            
            for pseudo_name, data in pairs(pseudo_module_files) do
                local pseudo_meta = { name = pseudo_name, module_root = data.root }; local pseudo_cache = module_cache.load(pseudo_meta)
                if pseudo_cache then
                    if pseudo_cache.files then for cat, files in pairs(pseudo_cache.files) do if files and #files > 0 then vim.list_extend(data.files, files) end end end
                    if pseudo_cache.directories then for cat, dirs in pairs(pseudo_cache.directories) do if dirs and #dirs > 0 then vim.list_extend(data.dirs, dirs) end end end
                end
                vim.list_extend(child_files, data.files or {})
                vim.list_extend(child_dirs, data.dirs or {})
            end
            
            for comp_name, component in pairs(required_components_map) do
                if component.owner_name == owner_name_to_match then
                    local root_file = component.uproject_path or component.uplugin_path
                    if root_file then table.insert(child_files, root_file) end

                    local relevant_modules = {}
                    for _, mtype in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do 
                      if component[mtype] then 
                        for mod_name, mod_meta in pairs(component[mtype]) do 
                          if filtered_modules_meta[mod_name] then 
                            relevant_modules[mod_name] = mod_meta 
                          end 
                        end 
                      end 
                    end
                    
                    for mod_name, mod_meta in pairs(relevant_modules) do
                        local mod_cache_data = module_cache.load(mod_meta)
                        if mod_cache_data then
                            if mod_cache_data.files then 
                              for cat, files in pairs(mod_cache_data.files) do 
                                if files and #files > 0 and cat ~= "programs" then 
                                  vim.list_extend(child_files, files) 
                                end 
                              end 
                            end
                            if mod_cache_data.directories then 
                              for cat, dirs in pairs(mod_cache_data.directories) do 
                                if dirs and #dirs > 0 and cat ~= "programs" then 
                                  vim.list_extend(child_dirs, dirs) 
                                end 
                              end 
                            end
                        end
                    end
                end
            end
            children = build_fs_hierarchy(node.path, child_files, child_dirs, false) 
            
        elseif node.extra.child_paths then
             children = build_fs_hierarchy(node.path, node.extra.child_paths.files, node.extra.child_paths.dirs, false) 
        end
        
    elseif uep_type == "fs" then
        if node.extra.child_paths then
             children = build_fs_hierarchy(node.path, node.extra.child_paths.files, node.extra.child_paths.dirs, false) 
        end
    end

    table.sort(children, directory_first_sorter)
    return children
end

function M.request(opts)
  if opts and opts.capability == "uep.get_pending_tree_request" then
    return M.get_pending_tree_request(opts)
  elseif opts and opts.capability == "uep.build_tree_model" then
    return M.build_tree_model(opts)
  elseif opts and opts.capability == "uep.load_tree_children" and opts.node then
    return M.load_children(opts.node)
  elseif opts and opts.capability == "uep.clear_tree_state" then
    return M.clear_tree_state()
  else
    uep_log.get().warn("Unknown request to UEP tree provider: %s", vim.inspect(opts))
    return nil
  end
end

return M
