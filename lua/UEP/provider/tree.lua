-- From: C:\Users\taku3\Documents\git\UEP.nvim\lua\UEP\provider\tree.lua
-- (UEP側で展開状態を記憶するステートフル版)

local unl_context = require("UNL.context")
local uep_log = require("UEP.logger") 
local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local module_cache = require("UEP.cache.module")
local fs = require("vim.fs")

local M = {}

-- ▼▼▼ 展開状態を保存するテーブルを追加 ▼▼▼
M.expanded_nodes = {} -- { ["category_Game"] = true, [".../Plugins"] = true }
-- ▲▲▲

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------

-- ソーター (変更なし)
local function directory_first_sorter(a, b)
  if a.type == "directory" and b.type ~= "directory" then return true
  elseif a.type ~= "directory" and b.type == "directory" then return false
  else return a.name < b.name end
end

-- (build_fs_hierarchy 関数は変更なし、ただし内部の M.load_children 呼び出しに備える)
local function build_fs_hierarchy(root_path, aggregated_files, aggregated_dirs)
    local log = uep_log.get()
    log.trace("build_fs_hierarchy called for root: %s", root_path)
    
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

    -- マップからノードリストを構築
    for name, node_type in pairs(direct_children_map) do
        local child_path = fs.joinpath(root_path, name)
        local has_children = (node_type == "directory" and grand_children_exist[name])
        
        local node_data = {
            id = child_path,
            name = name,
            path = child_path,
            type = node_type,
            children = has_children and {} or nil,
            loaded = not has_children, -- デフォルト (子がいなければ loaded=true)
            extra = {
                uep_type = "fs",
                -- [!] M.load_children が子をロードするために、
                -- [!] aggregated_files/dirs を引き継ぐことが重要
                child_paths = { files = aggregated_files, dirs = aggregated_dirs }
            }
        }

        -- ▼▼▼ M.expanded_nodes をチェックして再帰的に展開 ▼▼▼
        if has_children and M.expanded_nodes[child_path] then
            log.trace("Node '%s' was previously expanded, loading children recursively.", name)
            -- このノードは展開済みとしてマーク
            node_data.loaded = true
            -- M.load_children を再帰的に呼び出し、子ノードを取得
            node_data.children = M.load_children(node_data)
        end
        -- ▲▲▲

        table.insert(nodes, node_data)
    end

    table.sort(nodes, directory_first_sorter)
    log.trace("build_fs_hierarchy created %d direct children for: %s", #nodes, root_path)
    return nodes
end

-- (build_top_level_nodes 関数も M.expanded_nodes をチェックするように修正)
local function build_top_level_nodes(required_components_map, filtered_modules_meta, game_name, engine_name, project_root, engine_root)
    local top_nodes = {}
    local log = uep_log.get()
    
    -- 1. Gameカテゴリノードの準備
    local game_node = {
        id = "category_Game", 
        name = game_name,
        path = project_root, 
        type = "directory",
        children = {}, 
        loaded = false, -- [!] デフォルトは false
        extra = {
            uep_type = "category",
            -- [!] "重い" aggregated_files ではなく、"軽い" マップを渡す
            child_context = { 
                type = "GameRoot", 
                root = project_root, 
                engine_root = engine_root, 
                game_name = game_name, 
                engine_name = engine_name,
                -- [!] この2つを M.load_children に渡す
                required_components_map = required_components_map,
                filtered_modules_meta = filtered_modules_meta
            }
        }
    }
    
    -- ▼▼▼ Gameノードの展開状態をチェック ▼▼▼
    if M.expanded_nodes[game_node.id] then
        log.trace("Node 'Game' was previously expanded, loading children recursively.")
        game_node.loaded = true
        game_node.children = M.load_children(game_node) -- 子を即時ロード
    end
    table.insert(top_nodes, game_node)
    -- ▲▲▲

    -- 2. Engineカテゴリノードの準備
    local engine_node = {
        id = "category_Engine", 
        name = "Engine", 
        path = engine_root, 
        type = "directory",
        children = {}, 
        loaded = false, -- [!] デフォルトは false
        extra = {
            uep_type = "category",
            child_context = { 
                type = "EngineRoot", 
                root = engine_root, 
                game_name = game_name, 
                engine_name = engine_name,
                required_components_map = required_components_map,
                filtered_modules_meta = filtered_modules_meta
            }
        }
    }
    
    -- ▼▼▼ Engineノードの展開状態をチェック ▼▼▼
    if M.expanded_nodes[engine_node.id] then
        log.trace("Node 'Engine' was previously expanded, loading children recursively.")
        engine_node.loaded = true
        engine_node.children = M.load_children(engine_node) -- 子を即時ロード
    end
    table.insert(top_nodes, engine_node)
    -- ▲▲▲

    table.sort(top_nodes, directory_first_sorter)
    return top_nodes
end

-------------------------------------------------
-- プロバイダー公開関数 (修正版)
-------------------------------------------------

---
-- [New] ツリー状態リセットAPI
---
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
  
  -- ( ... STEP 4: モジュールのフィルタリング (高速) ... )
  local target_module_names = {}
  local requested_scope = (opts.scope and opts.scope:lower()) or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"
  log.info("Tree Provider: Filtering modules for scope='%s', deps_flag='%s'", requested_scope, deps_flag)
  local seed_modules = {}
  if requested_scope == "game" then for n, m in pairs(all_modules_map) do if m.owner_name == game_name then seed_modules[n] = true end end
  elseif requested_scope == "engine" then for n, m in pairs(all_modules_map) do if m.owner_name == engine_name then seed_modules[n] = true end end
  elseif requested_scope == "runtime" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
  elseif requested_scope == "developer" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
  elseif requested_scope == "editor" then for n, m in pairs(all_modules_map) do if m.type and m.type ~= "Program" then local ct = m.type:match("^%s*(.-)%s*$"):lower(); if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then seed_modules[n] = true end end end
  elseif requested_scope == "full" then for n,_ in pairs(all_modules_map) do seed_modules[n] = true end
  else requested_scope = "runtime"; for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
  end
  if deps_flag == "--no-deps" or requested_scope == "full" then target_module_names = seed_modules
  else
      local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"; local modules_to_process = vim.tbl_keys(seed_modules); local processed = {}
      while #modules_to_process > 0 do
          local current_name = table.remove(modules_to_process); if not processed[current_name] then processed[current_name] = true; target_module_names[current_name] = true
              local current_meta = all_modules_map[current_name]; if current_meta and current_meta[deps_key] then
                  for _, dep_name in ipairs(current_meta[deps_key]) do if not processed[dep_name] then local dep_meta = all_modules_map[dep_name]; if dep_meta then
                      local should_add = false; if requested_scope == "game" then should_add = (dep_meta.owner_name == game_name) elseif requested_scope == "engine" then should_add = (dep_meta.owner_name == engine_name) elseif requested_scope == "runtime" then should_add = (dep_meta.type == "Runtime") elseif requested_scope == "developer" then should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer") elseif requested_scope == "editor" then if dep_meta.type and dep_meta.type ~= "Program" then local ct = dep_meta.type:match("^%s*(.-)%s*$"):lower(); should_add = ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" end end
                      if should_add then table.insert(modules_to_process, dep_name) end
                  end end end
              end
          end
      end
  end
  local filtered_modules_meta = {}; for name, _ in pairs(target_module_names) do if all_modules_map[name] then filtered_modules_meta[name] = all_modules_map[name] end end
  local step4_filter_time = os.clock(); log.debug("Tree Provider: STEP 4 (Filtering) took %.4f seconds (%d modules)", step4_filter_time - step3_load_time, vim.tbl_count(filtered_modules_meta))

  -- ( ... STEP 5: 必要なコンポーネントを特定 (高速) ... )
  local required_components_map = {}; for mod_name, _ in pairs(filtered_modules_meta) do local comp_name = module_to_component_name[mod_name]; if comp_name and not required_components_map[comp_name] then required_components_map[comp_name] = all_components_map[comp_name] end end
  local step5_reqcomp_time = os.clock(); log.debug("Tree Provider: STEP 5 (Required Components) took %.4f seconds (%d components)", step5_reqcomp_time - step4_filter_time, vim.tbl_count(required_components_map))

  -- [!] STEP 6 (.module.json の全読み込み) は削除

  -- STEP 7: トップレベルノードを構築 (ステートフル版)
  local hierarchy_build_start_time = os.clock()
  -- [!] "重い" components_with_files の代わりに、"軽い" マップを渡す
  local top_level_nodes = build_top_level_nodes(required_components_map, filtered_modules_meta, game_name, engine_name, project_root, engine_root)
  local step7_hierarchy_time = os.clock()
  log.debug("Tree Provider: STEP 7 (Top Level Build) took %.4f seconds", step7_hierarchy_time - hierarchy_build_start_time)

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
-- [修正] M.load_children (重いデータ読み込みをここに集約)
function M.load_children(node)
    -- ▼▼▼ 展開状態を保存する ▼▼▼
    if node and node.id then
        M.expanded_nodes[node.id] = true
    end
    -- ▲▲▲
    
    local log = uep_log.get() 
    log.debug("Tree Provider: load_children called for node: %s (Type: %s)", node.name, node.extra and node.extra.uep_type or "fs")
    local start_time = os.clock()

    if not node or not node.extra then
        log.warn("load_children: Node extra data missing.")
        return {} -- 空のリストを返す
    end

    local children = {}
    local uep_type = node.extra.uep_type
    
    if uep_type == "category" or uep_type == "Game" or uep_type == "Engine" or uep_type == "Plugin" then
        local context = node.extra.child_context
        if context then
            -- A. "Game" または "Engine" カテゴリの場合
            -- [!] build_tree_model から渡された "軽い" マップを取得
            local required_components_map = context.required_components_map
            local filtered_modules_meta = context.filtered_modules_meta
            local owner_name_to_match = (context.type == "GameRoot") and context.game_name or context.engine_name
            
            local child_files = {} 
            local child_dirs = {}
            
            -- ▼▼▼ .module.json の読み込みと疑似モジュールのロードをここで行う ▼▼▼
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

                    -- このコンポーネントに属する、フィルタリング済みのモジュールを探す
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
                    
                    -- [!] .module.json をここで初めてロードする
                    for mod_name, mod_meta in pairs(relevant_modules) do
                        local mod_cache_data = module_cache.load(mod_meta)
                        if mod_cache_data then
                            if mod_cache_data.files then 
                              for cat, files in pairs(mod_cache_data.files) do 
                                -- [!] "source" カテゴリのファイルだけをツリーに追加
                                if files and #files > 0 and cat == "source" then 
                                  vim.list_extend(child_files, files) 
                                end 
                              end 
                            end
                            if mod_cache_data.directories then 
                              for cat, dirs in pairs(mod_cache_data.directories) do 
                                -- [!] "source" カテゴリのディレクトリだけをツリーに追加
                                if dirs and #dirs > 0 and cat == "source" then 
                                  vim.list_extend(child_dirs, dirs) 
                                end 
                              end 
                            end
                        end
                    end
                end
            end
            -- ▲▲▲ 修正完了 ▲▲▲

            children = build_fs_hierarchy(node.path, child_files, child_dirs)
            
        elseif node.extra.child_paths then
             -- B. "Plugins" ノード (または古い "MyProject" ノード) が展開された場合
             children = build_fs_hierarchy(node.path, node.extra.child_paths.files, node.extra.child_paths.dirs)
        end
        
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
