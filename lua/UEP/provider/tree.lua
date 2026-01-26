-- From: lua/UEP/provider/tree.lua
-- lua/UEP/provider/tree.lua
-- (Plugin Shaders 表示対応 & Content/Resources 完全除外版)

local unl_context = require("UNL.context")
local uep_log = require("UEP.logger") 
local uep_db = require("UEP.db.init")
local fs = require("vim.fs")
local uep_context = require("UEP.context")

local M = {}

local EXPANDED_STATE_KEY = "tree_expanded_state"

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------

local function load_files_from_db(module_name)
    local db = uep_db.get()
    if not db then return {}, {} end
    
    local db_query = require("UEP.db.query")
    local mod_id = db_query.get_module_id_by_name(db, module_name)
    if not mod_id then return {}, {} end
    
    local files = db_query.get_files_in_module(db, mod_id)
    local dirs = db_query.get_directories_in_module(db, mod_id)
    
    return files, dirs
end

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

local function build_top_level_nodes(required_components_map, filtered_modules_meta, game_name, engine_name, game_owner, engine_owner, project_root, engine_root)
    local top_nodes = {}
    local log = uep_log.get()
    
    local expanded_nodes = uep_context.get(EXPANDED_STATE_KEY) or {}
    
    if not game_owner then 
        game_owner = game_name 
    end
    if not engine_owner then engine_owner = engine_name end

    local game_node = {
        id = "category_Game", name = game_name, path = project_root, type = "directory",
        children = {}, loaded = false,
        extra = {
            uep_type = "category",
            child_context = { type = "GameRoot", root = project_root, engine_root = engine_root, game_name = game_name, engine_name = engine_name, required_components_map = required_components_map, filtered_modules_meta = filtered_modules_meta, game_owner = game_owner, engine_owner = engine_owner }
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
            child_context = { type = "EngineRoot", root = engine_root, game_name = game_name, engine_name = engine_name, required_components_map = required_components_map, filtered_modules_meta = filtered_modules_meta, game_owner = game_owner, engine_owner = engine_owner }
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

local function build_module_nodes(filtered_modules_meta)
    local log = uep_log.get()
    local top_nodes = {}
    
    for mod_name, mod_meta in pairs(filtered_modules_meta) do
        local source_files, source_dirs = load_files_from_db(mod_name)

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
    uep_context.del(EXPANDED_STATE_KEY)
    return true
end

function M.get_pending_tree_request(opts)
  local consumer_id = (opts and opts.consumer) or "unknown"
  local handle = unl_context.use("UEP"):key("pending_request:" .. consumer_id)
  local payload = handle:get("payload")
  
  -- Debug log
  local log = uep_log.get()
  if payload then
      log.debug("Found pending payload for consumer '" .. consumer_id .. "': " .. vim.inspect(payload))
      return payload
  else
      log.debug("No pending payload found for consumer '" .. consumer_id .. "'")
  end
  
  -- Fallback: Check global project payload (last resort)
  local global_handle = unl_context.use("UEP"):key("last_tree_payload")
  local global_payload = global_handle:get("payload")
  if global_payload then
      log.debug("Found global last_tree_payload: " .. vim.inspect(global_payload))
      return global_payload
  end

  log.debug("No payload found in pending_request or last_tree_payload.")

  return nil
end

function M.build_tree_model(opts)
  local log = uep_log.get()
  
  -- [Fix] Always merge pending request payload to ensure target_module is preserved.
  -- The consumer might call this with empty opts or partial opts.
  local request_payload = M.get_pending_tree_request({ consumer = "neo-tree-uproject" }) or {} 
  opts = vim.tbl_deep_extend("force", request_payload, opts or {})
  
  log.debug("Merged opts: " .. vim.inspect(opts))
  
  local project_root = opts.project_root
  local engine_root = opts.engine_root
  if not project_root then return nil end
  
  local db = uep_db.get()
  if not db then return {{ id = "_message_", name = "DB not available.", type = "message" }} end

  local db_query = require("UEP.db.query")
  local components = db_query.get_components(db) or {}
  local modules_rows = db_query.get_modules(db) or {}

  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  local game_name, engine_name
  local game_owner, engine_owner
  
  for _, comp in ipairs(components) do
      all_components_map[comp.name] = {
          name = comp.name,
          display_name = comp.display_name,
          type = comp.type,
          owner_name = comp.owner_name,
          root_path = comp.root_path,
          uplugin_path = comp.uplugin_path,
          uproject_path = comp.uproject_path,
          engine_association = comp.engine_association,
          runtime_modules = {},
          developer_modules = {},
          editor_modules = {},
          programs_modules = {}
      }
      if comp.type == "Game" then 
          game_name = comp.display_name
          game_owner = comp.owner_name 
      end
      if comp.type == "Engine" then 
          engine_name = comp.display_name
          engine_owner = comp.owner_name
      end
  end

  for _, row in ipairs(modules_rows) do
      local deep_deps = nil
      if row.deep_dependencies and row.deep_dependencies ~= "" then
          local ok, res = pcall(vim.json.decode, row.deep_dependencies)
          if ok then deep_deps = res end
      end

      local mod_meta = {
          name = row.name,
          type = row.type,
          scope = row.scope,
          module_root = row.root_path,
          path = row.build_cs_path,
          owner_name = row.owner_name,
          component_name = row.component_name,
          deep_dependencies = deep_deps
      }
      all_modules_map[row.name] = mod_meta
      module_to_component_name[row.name] = row.component_name
      
      if row.component_name and all_components_map[row.component_name] then
          local comp = all_components_map[row.component_name]
          local mtype = row.type
          if mtype == "Runtime" then comp.runtime_modules[row.name] = mod_meta
          elseif mtype == "Developer" then comp.developer_modules[row.name] = mod_meta
          elseif mtype == "Editor" then comp.editor_modules[row.name] = mod_meta
          elseif mtype == "Program" then comp.programs_modules[row.name] = mod_meta
          end
      end
  end
  
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
    -- 1. 展開状態を保存 (UI復元用)
    if node and node.id then
        local expanded_nodes = uep_context.get(EXPANDED_STATE_KEY) or {}
        expanded_nodes[node.id] = true
        uep_context.set(EXPANDED_STATE_KEY, expanded_nodes)
    end
    
    local log = uep_log.get() 
    -- (expanded_nodes は再帰呼び出し等で使う可能性がありますが、ここではローカル変数は使いません)

    if not node then return {} end
    
    -- extra 情報がない場合も許容 (Favorites などの外部ノード対応)
    local extra = node.extra or {}
    local children = {}
    local uep_type = extra.uep_type
    
    -- =========================================================
    -- パターン A: UEP論理ツリー (Category, Game, Engine, Plugin)
    -- =========================================================
    if uep_type == "category" or uep_type == "Game" or uep_type == "Engine" or uep_type == "Plugin" then
        local context = extra.child_context
        if context then
            local required_components_map = context.required_components_map
            local filtered_modules_meta = context.filtered_modules_meta
            local owner_name_to_match = (context.type == "GameRoot") and context.game_owner or context.engine_owner
            
            local child_files = {} 
            local child_dirs = {}
            
            -- A-1. 疑似モジュール (Config/Shaders)
            local pseudo_module_files = {}
            if context.type == "GameRoot" then
              pseudo_module_files._GameShaders = { root=fs.joinpath(context.root, "Shaders"), files={}, dirs={} }
              pseudo_module_files._GameConfig  = { root=fs.joinpath(context.root, "Config"), files={}, dirs={} }
            else 
              -- EngineRoot
              pseudo_module_files._EngineShaders = { root=fs.joinpath(context.root, "Engine", "Shaders"), files={}, dirs={} }
              pseudo_module_files._EngineConfig  = { root=fs.joinpath(context.root, "Engine", "Config"), files={}, dirs={} }
            end
            
            for pseudo_name, data in pairs(pseudo_module_files) do
                local f, d = load_files_from_db(pseudo_name)
                vim.list_extend(data.files, f)
                vim.list_extend(data.dirs, d)
                
                vim.list_extend(child_files, data.files or {})
                vim.list_extend(child_dirs, data.dirs or {})
            end
            
            -- A-2. コンポーネント (Game/Engine/Plugins)
            for comp_name, component in pairs(required_components_map) do
                if component.owner_name == owner_name_to_match then
                    
                    local root_file = component.uproject_path or component.uplugin_path
                    if root_file then table.insert(child_files, root_file) end

                    -- Pluginの疑似モジュール (Shaders/Config等) をロード
                    if component.type == "Plugin" then
                        local pseudo_name = component.type .. "_" .. component.display_name
                        local f, d = load_files_from_db(pseudo_name)

                        local function is_excluded(path)
                            if path:find("/Content/", 1, true) or path:match("/Content$") then return true end
                            if path:find("/Resources/", 1, true) or path:match("/Resources$") then return true end
                            return false
                        end

                        for _, file in ipairs(f) do
                            if not is_excluded(file) then table.insert(child_files, file) end
                        end
                        for _, dir in ipairs(d) do
                            if not is_excluded(dir) then table.insert(child_dirs, dir) end
                        end
                    end

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
                        local f, d = load_files_from_db(mod_name)
                        vim.list_extend(child_files, f)
                        vim.list_extend(child_dirs, d)
                    end
                end
            end
            children = build_fs_hierarchy(node.path, child_files, child_dirs, false) 
        end

    -- =========================================================
    -- パターン B: 既にパスリストを持っている場合 (再帰処理)
    -- =========================================================
    elseif (uep_type == "fs" or uep_type == "module_root") and extra.child_paths then
         children = build_fs_hierarchy(node.path, extra.child_paths.files, extra.child_paths.dirs, false) 
    
    -- =========================================================
    -- パターン C: 汎用パス検索 (Favorites などの外部リクエスト対応)
    -- =========================================================
    else
        -- ★★★ ここが追加・強化されたロジックです ★★★
        -- 「指定されたパス」以下のファイル/ディレクトリを、全キャッシュから動的に検索します。
        
        local target_path = node.path
        if target_path then
            -- 検索用: パス末尾を正規化
            local search_prefix = target_path:gsub("[/\\]$", "") .. "/"
            -- Windows対応: 大文字小文字の違いを吸収するため小文字化して比較に使用
            local search_prefix_lower = search_prefix:lower()

            -- 1. プロジェクト情報を取得
            local cwd = vim.loop.cwd()
            local project_root = require("UNL.finder").project.find_project_root(cwd)
            if project_root then
                local project_name = vim.fn.fnamemodify(project_root, ":t")
                local reg = projects_cache.get_project_info(project_name)
                
                local found_files = {}
                local found_dirs = {}
                
                if reg and reg.components then
                    -- 2. 全コンポーネントを走査
                    for _, cname in ipairs(reg.components) do
                        local p_cache = project_cache.load(cname .. ".project.json")
                        if p_cache then
                            -- 3. 全モジュールを走査
                            local types = {"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}
                            local modules_to_scan = {}

                            for _, t in ipairs(types) do
                                if p_cache[t] then
                                    for mname, mmeta in pairs(p_cache[t]) do
                                        table.insert(modules_to_scan, mmeta)
                                    end
                                end
                            end
                            
                            -- 疑似モジュール (Game/Pluginルート) も追加
                            if (p_cache.type == "Game" or p_cache.type == "Plugin") and p_cache.root_path then
                                local pseudo_name = p_cache.type .. "_" .. p_cache.display_name
                                table.insert(modules_to_scan, { name=pseudo_name, module_root=p_cache.root_path })
                            end

                            -- 4. 各モジュールのキャッシュからパス一致を検索
                            for _, mod_meta in ipairs(modules_to_scan) do
                                -- 最適化: モジュールルートがターゲットパスと全く関係なければスキップ
                                -- (モジュールがターゲットの中にあるか、ターゲットがモジュールの中にある場合のみスキャン)
                                local m_root = mod_meta.module_root
                                if m_root then
                                    local m_root_lower = m_root:lower()
                                    -- 交差判定 (どちらかがどちらかを含んでいる)
                                    if m_root_lower:find(search_prefix_lower, 1, true) or search_prefix_lower:find(m_root_lower, 1, true) then
                                        
                                        local cache = module_cache.load(mod_meta)
                                        if cache then
                                            if cache.files then
                                                for _, list in pairs(cache.files) do
                                                    for _, f in ipairs(list) do
                                                        -- ファイルパスがターゲットパスで始まっているか
                                                        if f:lower():find(search_prefix_lower, 1, true) == 1 then 
                                                            table.insert(found_files, f) 
                                                        end
                                                    end
                                                end
                                            end
                                            if cache.directories then
                                                for _, list in pairs(cache.directories) do
                                                    for _, d in ipairs(list) do
                                                        if d:lower():find(search_prefix_lower, 1, true) == 1 then 
                                                            table.insert(found_dirs, d) 
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                
                -- 5. Engine側の疑似モジュール (Config/Shaders) も必要なら検索
                -- (今回はプロジェクトメインの検索に絞っていますが、必要ならここに追加可能)

                if #found_files > 0 or #found_dirs > 0 then
                    -- 見つかったファイル群から、直下の階層構造を構築
                    children = build_fs_hierarchy(target_path, found_files, found_dirs, false)
                end
            end
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
  elseif opts and opts.capability == "uep.update_module_cache" and opts.module_name then
    -- モジュールキャッシュの更新
    local module_name = opts.module_name
    local refresher = require("UEP.cmd.core.refresh_modules")
    
    -- 非同期実行されるが、ここではリクエスト受付を返す
    -- 必要なら将来的にコールバックやPromise対応を行う
    if refresher and refresher.update_single_module_cache then
       refresher.update_single_module_cache(module_name, function() 
         -- 完了時のログなどは refresher 側で行われる想定
       end)
       return { accepted = true }
    end
    return nil
  elseif opts and opts.capability == "uep.clear_tree_state" then
    return M.clear_tree_state()
  else
    uep_log.get().warn("Unknown request to UEP tree provider: %s", vim.inspect(opts))
    return nil
  end
end

return M
