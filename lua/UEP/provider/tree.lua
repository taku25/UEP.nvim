-- From: C:\Users\taku3\Documents\git\UEP.nvim\lua\UEP\provider\tree.lua
-- (:UEP module_tree でEagerロードを実装)

local unl_context = require("UNL.context")
local uep_log = require("UEP.logger") 
local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local module_cache = require("UEP.cache.module")
local fs = require("vim.fs")

local M = {}

M.expanded_nodes = {} 

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------

local function directory_first_sorter(a, b)
  if a.type == "directory" and b.type ~= "directory" then return true
  elseif a.type ~= "directory" and b.type == "directory" then return false
  else return a.name < b.name end
end

-- ▼▼▼ 修正: build_fs_hierarchy を Eager/Lazy 両対応にする ▼▼▼
local function build_fs_hierarchy(root_path, aggregated_files, aggregated_dirs, is_eager)
    local log = uep_log.get()
    log.trace("build_fs_hierarchy called for root: %s (Eager: %s)", root_path, tostring(is_eager))
    
    local nodes = {}
    local direct_children_map = {} 
    local grand_children_exist = {} 

    local root_prefix = root_path:gsub("[/\\]$", "") .. "/"
    local root_prefix_lower = root_prefix:lower()
    local root_prefix_len = #root_prefix

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
        
        -- [!] is_eager または M.expanded_nodes[child_path] の場合に再帰
        if has_children and (is_eager or M.expanded_nodes[child_path]) then
            log.trace("Node '%s' is being expanded (Eager: %s, Cached: %s).", name, tostring(is_eager), tostring(M.expanded_nodes[child_path]))
            node_data.loaded = true
            -- [!] M.load_children ではなく、自分自身 (build_fs_hierarchy) を Eager で再帰呼び出し
            node_data.children = build_fs_hierarchy(child_path, aggregated_files, aggregated_dirs, is_eager)
        end
        table.insert(nodes, node_data)
    end
    table.sort(nodes, directory_first_sorter)
    log.trace("build_fs_hierarchy created %d direct children for: %s", #nodes, root_path)
    return nodes
end
-- ▲▲▲

-- (build_top_level_nodes 関数は変更なし)
-- (M.expanded_nodes[game_node.id] をチェックするロジックも含む)
local function build_top_level_nodes(required_components_map, filtered_modules_meta, game_name, engine_name, project_root, engine_root)
    local top_nodes = {}
    local log = uep_log.get()
    
    local game_node = {
        id = "category_Game", name = game_name, path = project_root, type = "directory",
        children = {}, loaded = false,
        extra = {
            uep_type = "category",
            child_context = { type = "GameRoot", root = project_root, engine_root = engine_root, game_name = game_name, engine_name = engine_name, required_components_map = required_components_map, filtered_modules_meta = filtered_modules_meta }
        }
    }
    if M.expanded_nodes[game_node.id] then
        log.trace("Node 'Game' was previously expanded, loading children recursively.")
        game_node.loaded = true
        game_node.children = M.load_children(game_node)
    end
    table.insert(top_nodes, game_node)

    local engine_node = {
        id = "category_Engine", name = "Engine", path = engine_root, type = "directory",
        children = {}, loaded = false,
        extra = {
            uep_type = "category",
            child_context = { type = "EngineRoot", root = engine_root, game_name = game_name, engine_name = engine_name, required_components_map = required_components_map, filtered_modules_meta = filtered_modules_meta }
        }
    }
    if M.expanded_nodes[engine_node.id] then
        log.trace("Node 'Engine' was previously expanded, loading children recursively.")
        engine_node.loaded = true
        engine_node.children = M.load_children(engine_node)
    end
    table.insert(top_nodes, engine_node)

    table.sort(top_nodes, directory_first_sorter)
    return top_nodes
end

-- ▼▼▼ 修正: Eagerロードを実行する 'build_module_nodes' ▼▼▼
local function build_module_nodes(filtered_modules_meta)
    local log = uep_log.get()
    local top_nodes = {}
    
    for mod_name, mod_meta in pairs(filtered_modules_meta) do
        -- 1. このモジュールの .module.json をロード (Eager)
        local mod_cache_data = module_cache.load(mod_meta)
        local source_files = {}
        local source_dirs = {}
        if mod_cache_data then
            if mod_cache_data.files and mod_cache_data.files.source then
                vim.list_extend(source_files, mod_cache_data.files.source)
            end
            if mod_cache_data.directories and mod_cache_data.directories.source then
                vim.list_extend(source_dirs, mod_cache_data.directories.source)
            end
        end

        -- 2. build_fs_hierarchy を Eager モードで呼び出し、完全なツリーを構築
        local children_nodes = build_fs_hierarchy(mod_meta.module_root, source_files, source_dirs, true) -- [!] true = Eager

        local node_data = {
            id = "module_root_" .. mod_name,
            name = mod_name,
            path = mod_meta.module_root,
            type = "directory",
            children = children_nodes,
            loaded = true, -- [!] Eagerロードしたので loaded = true
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
-- ▲▲▲

-------------------------------------------------
-- プロバイダー公開関数 (修正版)
-------------------------------------------------

function M.clear_tree_state()
    local log = uep_log.get()
    log.debug("Tree Provider: Clearing expanded node state.")
    M.expanded_nodes = {}
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
  
  local start_time = os.clock()
  local request_payload = M.get_pending_tree_request({ consumer = "neo-tree-uproject" }) or {} 
  opts = vim.tbl_deep_extend("force", opts or {}, request_payload)
  
  -- ( ... STEP 1-3: .project.json のロード (高速) ... )
  local project_root = opts.project_root
  local engine_root = opts.engine_root
  if not project_root then return nil end
  log.debug("Tree Provider: Starting build_tree_model (True Lazy)...")
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then
    return {{ id = "_message_", name = "Project not registered.", type = "message" }}
  end
  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  local game_name, engine_name
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
      if p_cache.type == "Game" then game_name = p_cache.display_name end
      if p_cache.type == "Engine" then engine_name = p_cache.display_name end
    end
  end
  if not next(all_modules_map) then return {{ id = "_message_", name = "No modules in cache.", type = "message" }} end
  if not game_name or not engine_name then return {{ id = "_message_", name = "Game/Engine component missing.", type = "message" }} end
  local step3_load_time = os.clock()
  log.debug("Tree Provider: STEP 1-3 (Load Cache) took %.4f seconds", step3_load_time - start_time)
  
  -- ▼▼▼ 修正: STEP 4 のロジックを修正 ▼▼▼
  local target_module_names = {}
  local requested_scope = (opts.scope and opts.scope:lower()) or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"
  log.info("Tree Provider: Filtering modules for scope='%s', deps_flag='%s'", requested_scope, deps_flag)
  
  local seed_modules = {}
  if opts.target_module then
    log.info("Tree Provider: Building tree for single target module: %s", opts.target_module)
    if all_modules_map[opts.target_module] then
        seed_modules[opts.target_module] = true
    else
        log.warn("Tree Provider: Target module '%s' not found in map.", opts.target_module)
        return {{ id = "_message_", name = "Module not found: " .. opts.target_module, type = "message" }}
    end
  else
    log.info("Tree Provider: Building tree for scope: %s", requested_scope)
    if requested_scope == "game" then for n, m in pairs(all_modules_map) do if m.owner_name == game_name then seed_modules[n] = true end end
    elseif requested_scope == "engine" then for n, m in pairs(all_modules_map) do if m.owner_name == engine_name then seed_modules[n] = true end end
    elseif requested_scope == "runtime" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
    elseif requested_scope == "developer" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
    elseif requested_scope == "editor" then for n, m in pairs(all_modules_map) do if m.type and m.type ~= "Program" then local ct = m.type:match("^%s*(.-)%s*$"):lower(); if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then seed_modules[n] = true end end end
    elseif requested_scope == "full" then for n,_ in pairs(all_modules_map) do seed_modules[n] = true end
    else requested_scope = "runtime"; for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
  end
  end
  
  -- [!] :UEP module_tree の場合は deps_flag を無視する
  if deps_flag == "--no-deps" or opts.target_module then
    target_module_names = seed_modules
  else
    local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
    local modules_to_process = vim.tbl_keys(seed_modules)
    local processed = {}
    while #modules_to_process > 0 do
        local current_name = table.remove(modules_to_process)
        if not processed[current_name] then 
            processed[current_name] = true
            target_module_names[current_name] = true
            local current_meta = all_modules_map[current_name]
            if current_meta and current_meta[deps_key] then
                for _, dep_name in ipairs(current_meta[deps_key]) do 
                    if not processed[dep_name] then 
                        local dep_meta = all_modules_map[dep_name]
                        if dep_meta then
                            -- [!] :UEP tree の場合はスコープでフィルタリング
                            local should_add = false
                            if requested_scope == "game" then should_add = (dep_meta.owner_name == game_name) elseif requested_scope == "engine" then should_add = (dep_meta.owner_name == engine_name) elseif requested_scope == "runtime" then should_add = (dep_meta.type == "Runtime") elseif requested_scope == "developer" then should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer") elseif requested_scope == "editor" then if dep_meta.type and dep_meta.type ~= "Program" then local ct = dep_meta.type:match("^%s*(.-)%s*$"):lower(); should_add = ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" end end
                            
                            if should_add then table.insert(modules_to_process, dep_name) end
                        end 
                    end 
                end
            end
        end
    end
  end
  -- ▲▲▲ 修正完了 ▲▲▲
      
  local filtered_modules_meta = {}; for name, _ in pairs(target_module_names) do if all_modules_map[name] then filtered_modules_meta[name] = all_modules_map[name] end end
  local step4_filter_time = os.clock(); log.debug("Tree Provider: STEP 4 (Filtering) took %.4f seconds (%d modules)", step4_filter_time - step3_load_time, vim.tbl_count(filtered_modules_meta))

  -- ( ... STEP 5: 必要なコンポーネントを特定 (高速) ... )
  local required_components_map = {}; for mod_name, _ in pairs(filtered_modules_meta) do local comp_name = module_to_component_name[mod_name]; if comp_name and not required_components_map[comp_name] then required_components_map[comp_name] = all_components_map[comp_name] end end
  local step5_reqcomp_time = os.clock(); log.debug("Tree Provider: STEP 5 (Required Components) took %.4f seconds (%d components)", step5_reqcomp_time - step4_filter_time, vim.tbl_count(required_components_map))

  -- [!] STEP 6 (.module.json の全読み込み) は削除

  -- ▼▼▼ 修正: STEP 7 を分岐させる ▼▼▼
  local hierarchy_build_start_time = os.clock()
  local top_level_nodes
  
  if opts.target_module then
      -- :UEP module_tree の場合
      log.debug("Tree Provider: Building module-only tree (Eagerly).")
      top_level_nodes = build_module_nodes(filtered_modules_meta)
  else
      -- :UEP tree の場合
      log.debug("Tree Provider: Building standard Game/Engine tree (Lazily).")
      top_level_nodes = build_top_level_nodes(required_components_map, filtered_modules_meta, game_name, engine_name, project_root, engine_root)
  end
  
  local step7_hierarchy_time = os.clock()
  log.debug("Tree Provider: STEP 7 (Tree Build) took %.4f seconds", step7_hierarchy_time - hierarchy_build_start_time)
  -- ▲▲▲ 修正完了 ▲▲▲

  if not next(top_level_nodes) then
    return {{ id = "_message_", name = "No components/files to display for current scope/deps.", type = "message" }}
  end

  -- STEP 8: ルートノードを返す (トップレベルノードのみを含む)
  local end_time = os.clock()
  log.info("Tree Provider: Total execution time: %.4f seconds", end_time - start_time)
  return {{
    id = "logical_root",
    name = project_display_name or "Logical View",
    path = project_root, type = "directory",
    loaded = true,
    children = top_level_nodes, 
    extra = { uep_type = "project_root" },
  }}
end


---
-- [修正] M.load_children (uep_type == "module_root" を削除)
function M.load_children(node)
    if node and node.id then
        M.expanded_nodes[node.id] = true
    end
    
    local log = uep_log.get() 
    log.debug("Tree Provider: load_children called for node: %s (Type: %s)", node.name, node.extra and node.extra.uep_type or "fs")
    local start_time = os.clock()

    if not node or not node.extra then
        log.warn("load_children: Node extra data missing.")
        return {}
    end

    local children = {}
    local uep_type = node.extra.uep_type
    
    if uep_type == "category" or uep_type == "Game" or uep_type == "Engine" or uep_type == "Plugin" then
        -- 1. "Game", "Engine" カテゴリが展開された場合
        local context = node.extra.child_context
        if context then
            -- A. "Game" または "Engine" カテゴリの場合
            local required_components_map = context.required_components_map
            local filtered_modules_meta = context.filtered_modules_meta
            local owner_name_to_match = (context.type == "GameRoot") and context.game_name or context.engine_name
            local child_files = {} 
            local child_dirs = {}
            
            -- .module.json の読み込みと疑似モジュールのロードをここで行う
            local pseudo_module_files = {}
            if context.type == "GameRoot" then
              pseudo_module_files._GameShaders = { root=fs.joinpath(context.root, "Shaders"), files={}, dirs={} }
              pseudo_module_files._GameConfig  = { root=fs.joinpath(context.root, "Config"), files={}, dirs={} }
            else -- EngineRoot
              pseudo_module_files._EngineShaders = { root=fs.joinpath(context.root, "Engine", "Shaders"), files={}, dirs={} }
              pseudo_module_files._EngineConfig  = { root=fs.joinpath(context.root, "Engine", "Config"), files={}, dirs={} }
            end
            
            -- 疑似モジュールのキャッシュをロード
            for pseudo_name, data in pairs(pseudo_module_files) do
                local pseudo_meta = { name = pseudo_name, module_root = data.root }; local pseudo_cache = module_cache.load(pseudo_meta)
                if pseudo_cache then
                    if pseudo_cache.files then for cat, files in pairs(pseudo_cache.files) do if files and #files > 0 then vim.list_extend(data.files, files) end end end
                    if pseudo_cache.directories then for cat, dirs in pairs(pseudo_cache.directories) do if dirs and #dirs > 0 then vim.list_extend(data.dirs, dirs) end end end
                end
                vim.list_extend(child_files, data.files or {})
                vim.list_extend(child_dirs, data.dirs or {})
            end
            
            -- 実際のコンポーネント処理 (重い .module.json の読み込み)
            for comp_name, component in pairs(required_components_map) do
                if component.display_name == owner_name_to_match then
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
                                if files and #files > 0 and cat == "source" then 
                                  vim.list_extend(child_files, files) 
                                end 
                              end 
                            end
                            if mod_cache_data.directories then 
                              for cat, dirs in pairs(mod_cache_data.directories) do 
                                if dirs and #dirs > 0 and cat == "source" then 
                                  vim.list_extend(child_dirs, dirs) 
                                end 
                              end 
                            end
                        end
                    end
                end
            end
            children = build_fs_hierarchy(node.path, child_files, child_dirs, false) -- [!] Eager = false
            
        elseif node.extra.child_paths then
             -- B. "Plugins" ノード (または古い "MyProject" ノード) が展開された場合
             children = build_fs_hierarchy(node.path, node.extra.child_paths.files, node.extra.child_paths.dirs, false) -- [!] Eager = false
        end
        
    -- ▼▼▼ 修正: "module_root" タイプは Eagerロードされたので、ここでは何もしない ▼▼▼
    -- elseif uep_type == "module_root" then
    -- ▲▲▲
            
    elseif uep_type == "fs" then
        -- 2. "fs" (ファイルシステム上のディレクトリ) が展開された場合
        if node.extra.child_paths then
             -- [!] M.expanded_nodes をチェックするため、M.load_children を再帰的に呼ぶ
             
             local aggregated_files = node.extra.child_paths.files
             local aggregated_dirs = node.extra.child_paths.dirs
             local root_path = node.path
             
             local direct_children_map = {} 
             local grand_children_exist = {} 

             local root_prefix = root_path:gsub("[/\\]$", "") .. "/"
             local root_prefix_lower = root_prefix:lower()
             local root_prefix_len = #root_prefix

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
                 if has_children and M.expanded_nodes[child_path] then
                     log.trace("Node '%s' was previously expanded, loading children recursively.", name)
                     node_data.loaded = true
                     node_data.children = M.load_children(node_data)
                 end
                 table.insert(children, node_data)
             end
        end
    end

    table.sort(children, directory_first_sorter)
    local end_time = os.clock()
    log.debug("Tree Provider: load_children for '%s' took %.4f seconds, found %d children", node.name, end_time - start_time, #children)
    return children
end

---
-- メインのリクエストハンドラ ( capability に応じて振り分ける)
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
