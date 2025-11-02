-- From: C:\Users\taku3\Documents\git\UEP.nvim\lua\UEP\provider\tree.lua
-- lua/UEP/provider/tree.lua (プラグインソースのバグと空ノードのバグを修正)

local unl_context = require("UNL.context")
local uep_log = require("UEP.logger") 
local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local module_cache = require("UEP.cache.module")
local fs = require("vim.fs")

local M = {}

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------

-- ソーター (変更なし)
local function directory_first_sorter(a, b)
  if a.type == "directory" and b.type ~= "directory" then return true
  elseif a.type ~= "directory" and b.type == "directory" then return false
  else return a.name < b.name end
end

---
-- [修正] ファイル/ディレクトリのリストから「直下の子ノード」のみを生成する
-- @param root_path string 親ノードのパス
-- @param aggregated_files table { "path/to/file.h", ... }
-- @param aggregated_dirs table { "path/to/dir", ... }
-- @return table
local function build_fs_hierarchy(root_path, aggregated_files, aggregated_dirs)
    local log = uep_log.get()
    log.trace("build_fs_hierarchy called for root: %s", root_path)
    
    local nodes = {}
    local direct_children_map = {} -- { "dirname" = "directory", "filename.h" = "file" }
    local grand_children_exist = {} -- { "dirname" = true }

    local root_prefix = root_path:gsub("[/\\]$", "") .. "/"
    local root_prefix_lower = root_prefix:lower()
    local root_prefix_len = #root_prefix

    local function process_paths(paths, item_type)
        for _, raw_full_path in ipairs(paths or {}) do
            local full_path_lower = raw_full_path:lower()

            if full_path_lower:sub(1, root_prefix_len) == root_prefix_lower then
                local relative_path = raw_full_path:sub(root_prefix_len + 1)
                
                -- ▼▼▼ 修正点 2: 空のパス（＝自分自身）を無視する ▼▼▼
                if relative_path ~= "" then
                  local separator_pos = relative_path:find("[/\\]")
                  
                  if separator_pos then
                      -- 孫以降のパス
                      local first_part = relative_path:sub(1, separator_pos - 1)
                      if not direct_children_map[first_part] then
                          -- まだマップにない場合、ディレクトリとして登録
                          direct_children_map[first_part] = "directory"
                      end
                      -- このディレクトリは子を持つ
                      grand_children_exist[first_part] = true
                  else
                      -- 直下の子
                      if not direct_children_map[relative_path] then
                         direct_children_map[relative_path] = item_type
                      end
                  end
                end
                -- ▲▲▲ 修正点 2 完了 ▲▲▲
            end
        end
    end

    process_paths(aggregated_dirs, "directory")
    process_paths(aggregated_files, "file")

    -- マップからノードリストを構築
    for name, node_type in pairs(direct_children_map) do
        local child_path = fs.joinpath(root_path, name)
        local has_children = (node_type == "directory" and grand_children_exist[name])
        
        table.insert(nodes, {
            id = child_path,
            name = name,
            path = child_path,
            type = node_type,
            -- [!] neo-treeが 'loaded' を見る
            loaded = not has_children, -- 子がいなければ(true)、いれば(false)
            children = has_children and {} or nil, -- 子がいれば空テーブル
            extra = {
                uep_type = "fs",
                -- [!] 重要な情報: 子の検索に必要な情報を引き継ぐ
                child_paths = { files = aggregated_files, dirs = aggregated_dirs }
            }
        })
    end

    table.sort(nodes, directory_first_sorter)
    log.trace("build_fs_hierarchy created %d direct children for: %s", #nodes, root_path)
    return nodes
end

---
-- [修正] トップレベルノード (Game, Engine, Plugins) のみを構築する
local function build_top_level_nodes(components_with_files, pseudo_module_files, game_name, engine_name, project_root, engine_root)
    local top_nodes = {}
    
    -- 1. Gameカテゴリノードの準備
    local game_node = {
        id = "category_Game", name = game_name, path = project_root, type = "directory",
        -- [!] 子ノードは空にし、loaded = false を設定
        children = {}, loaded = false,
        extra = {
            uep_type = "category",
            -- [!] 子ノードの構築に必要な情報を extra に詰める
            child_context = {
                type = "GameRoot",
                root = project_root,
                engine_root = engine_root,
                game_name = game_name,
                engine_name = engine_name,
                components = components_with_files,
                pseudo_files = pseudo_module_files
            }
        }
    }
    -- (Gameノードは基本的に常に追加)
    table.insert(top_nodes, game_node)

    -- 2. Engineカテゴリノードの準備
    local engine_node = {
        id = "category_Engine", name = "Engine", path = engine_root, type = "directory",
        children = {}, loaded = false,
        extra = {
            uep_type = "category",
            child_context = {
                type = "EngineRoot",
                root = engine_root,
                game_name = game_name,
                engine_name = engine_name,
                components = components_with_files,
                pseudo_files = pseudo_module_files
            }
        }
    }
    -- (Engineノードも基本的に常に追加)
    table.insert(top_nodes, engine_node)

    table.sort(top_nodes, directory_first_sorter)
    return top_nodes
end

-------------------------------------------------
-- プロバイダー公開関数 (修正版)
-------------------------------------------------
function M.get_pending_tree_request(opts)
  local consumer_id = (opts and opts.consumer) or "unknown"
  local handle = unl_context.use("UEP"):key("pending_request:" .. consumer_id)
  local payload = handle:get("payload")
  if payload then handle:del("payload"); return payload end
  return nil
end

---
-- [修正] M.build_tree_model (トップレベルノードのみを返す)
function M.build_tree_model(opts)
  local start_time = os.clock()
  local log = uep_log.get()

  -- (STEP 1-5: 必要なデータ（モジュールマップ、コンポーネントマップ）のロード)
  -- ( ... 変更なし ... )
  local request_payload = M.get_pending_tree_request({ consumer = "neo-tree-uproject" }) or {}
  opts = vim.tbl_deep_extend("force", opts or {}, request_payload)
  local project_root = opts.project_root
  local engine_root = opts.engine_root
  if not project_root then return nil end
  log.debug("Tree Provider: Starting build_tree_model (Lazy)...")
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
-- ▼▼▼ ここを修正 ▼▼▼
      if p_cache.type == "Game" then game_name = p_cache.display_name end -- comp_name から p_cache.display_name に変更
      if p_cache.type == "Engine" then engine_name = p_cache.display_name end -- comp_name から p_cache.display_name に変更
      -- ▲▲▲ 修正完了 ▲▲▲
    end
  end
  if not next(all_modules_map) then return {{ id = "_message_", name = "No modules in cache.", type = "message" }} end
  if not game_name or not engine_name then return {{ id = "_message_", name = "Game/Engine component missing.", type = "message" }} end
  local step3_load_time = os.clock()
  log.debug("Tree Provider: STEP 1-3 (Load Cache) took %.4f seconds", step3_load_time - start_time)
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
  local required_components_map = {}; for mod_name, _ in pairs(filtered_modules_meta) do local comp_name = module_to_component_name[mod_name]; if comp_name and not required_components_map[comp_name] then required_components_map[comp_name] = all_components_map[comp_name] end end
  local step5_reqcomp_time = os.clock(); log.debug("Tree Provider: STEP 5 (Required Components) took %.4f seconds (%d components)", step5_reqcomp_time - step4_filter_time, vim.tbl_count(required_components_map))

  -- STEP 6: モジュールキャッシュからファイル情報を「集計」 (変更あり)
  local components_with_files = {};
  local pseudo_module_files = {
      _EngineShaders = { root=fs.joinpath(engine_root, "Engine", "Shaders"), files={}, dirs={} },
      _EngineConfig  = { root=fs.joinpath(engine_root, "Engine", "Config"), files={}, dirs={} },
      _GameShaders   = { root=fs.joinpath(project_root, "Shaders"), files={}, dirs={} },
      _GameConfig    = { root=fs.joinpath(project_root, "Config"), files={}, dirs={} },
  }
  local cache_load_start_time = os.clock()
  -- 6a: 実際のコンポーネント処理
  for comp_name, component_meta in pairs(required_components_map) do
      -- [!] ここで集計する aggregated_files/dirs は、
      -- [!] "Game" "Engine" "Plugins" ノードが子をロードするときに使われる
      local aggregated_files = { source={}, config={}, shader={}, programs={}, other={}, content={} }
      local aggregated_dirs = { source={}, config={}, shader={}, programs={}, other={}, content={} }
      local has_any_files = false
      local relevant_modules = {}
      for _, mtype in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do if component_meta[mtype] then for mod_name, mod_meta in pairs(component_meta[mtype]) do if filtered_modules_meta[mod_name] then relevant_modules[mod_name] = mod_meta end end end end
      
      for mod_name, mod_meta in pairs(relevant_modules) do
          local mod_cache_data = module_cache.load(mod_meta)
          if mod_cache_data then
              if mod_cache_data.files then for cat, files in pairs(mod_cache_data.files) do if files and #files > 0 then if not aggregated_files[cat] then aggregated_files[cat] = {} end; vim.list_extend(aggregated_files[cat], files); has_any_files = true end end end
              if mod_cache_data.directories then for cat, dirs in pairs(mod_cache_data.directories) do if dirs and #dirs > 0 then if not aggregated_dirs[cat] then aggregated_dirs[cat] = {} end; vim.list_extend(aggregated_dirs[cat], dirs); has_any_files = true end end end
          end
      end
      if has_any_files then component_meta.aggregated_files = aggregated_files; component_meta.aggregated_dirs = aggregated_dirs; table.insert(components_with_files, component_meta) end
  end
  -- 6b: 疑似モジュールのキャッシュをロード
  for pseudo_name, data in pairs(pseudo_module_files) do
      local pseudo_meta = { name = pseudo_name, module_root = data.root }; local pseudo_cache = module_cache.load(pseudo_meta)
      if pseudo_cache then
          if pseudo_cache.files then for cat, files in pairs(pseudo_cache.files) do if files and #files > 0 then vim.list_extend(data.files, files) end end end
          if pseudo_cache.directories then for cat, dirs in pairs(pseudo_cache.directories) do if dirs and #dirs > 0 then vim.list_extend(data.dirs, dirs) end end end
      end
  end
  local step6_cache_time = os.clock()
  log.debug("Tree Provider: STEP 6 (Cache Load) took %.4f seconds", step6_cache_time - step5_reqcomp_time)

  -- STEP 7: トップレベルノードを構築 (遅延読み込み対応版)
  local hierarchy_build_start_time = os.clock()
  local top_level_nodes = build_top_level_nodes(components_with_files, pseudo_module_files, game_name, engine_name, project_root, engine_root)
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
    -- [!] ルートノードは常に展開済み (loaded = true)
    loaded = true,
    children = top_level_nodes, -- ★ トップレベルノードのリスト
    extra = { uep_type = "project_root" },
  }}
end


---
-- [新規] M.load_children (子ノードの動的読み込み)
function M.load_children(node)
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
        -- 1. "Game", "Engine", "Plugins" カテゴリ、または "MyProject" コンポーネントが展開された場合
        local context = node.extra.child_context
        if context then
            -- A. "Game" または "Engine" カテゴリの場合
            local components = context.components
            local pseudo_files = context.pseudo_files
            local owner_name_to_match = (context.type == "GameRoot") and context.game_name or context.engine_name
            
            local child_files = {} -- Config, Shaders などのファイル
            local child_dirs = {}
            
            -- ( ... 疑似モジュールのファイル追加ロジック ... )
            for pseudo_name, data in pairs(pseudo_files or {}) do
                if (context.type == "GameRoot" and (pseudo_name == "_GameShaders" or pseudo_name == "_GameConfig")) or
                   (context.type == "EngineRoot" and (pseudo_name == "_EngineShaders" or pseudo_name == "_EngineConfig")) then
                    vim.list_extend(child_files, data.files or {})
                    vim.list_extend(child_dirs, data.dirs or {})
                end
            end
            
            -- コンポーネント (Game, Engine, Plugin) を処理
            for _, component in ipairs(components) do

                -- ▼▼▼ ここを修正 ▼▼▼
                -- if component.owner_name == owner_name_to_match then
                if component.display_name == owner_name_to_match then -- [!] .owner_name を .display_name に変更
                -- ▲▲▲ 修正完了 ▲▲▲

                    -- .uproject, .uplugin ファイルを追加
                    local root_file = component.uproject_path or component.uplugin_path
                    if root_file then table.insert(child_files, root_file) end

                    -- ソースファイル/ディレクトリを集計
                    local comp_files = (component.aggregated_files and component.aggregated_files.source) or {}
                    local comp_dirs = (component.aggregated_dirs and component.aggregated_dirs.source) or {}
                    
                    if component.type == "Plugin" then
                        vim.list_extend(child_files, comp_files)
                        vim.list_extend(child_dirs, comp_dirs)  
                    else -- Game または Engine
                        vim.list_extend(child_files, comp_files)
                        vim.list_extend(child_dirs, comp_dirs)
                    end
                end
            end

            -- Game/Engine 直下のファイル/ディレクトリを生成
            children = build_fs_hierarchy(node.path, child_files, child_dirs)
            
        elseif node.extra.child_paths then
             -- B. "Plugins" ノード (または古い "MyProject" ノード) が展開された場合
             children = build_fs_hierarchy(node.path, node.extra.child_paths.files, node.extra.child_paths.dirs)
        end
        
    elseif uep_type == "fs" then
        -- 2. "fs" (ファイルシステム上のディレクトリ) が展開された場合
        if node.extra.child_paths then
             children = build_fs_hierarchy(node.path, node.extra.child_paths.files, node.extra.child_paths.dirs)
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
  else
    uep_log.get().warn("Unknown request to UEP tree provider: %s", vim.inspect(opts))
    return nil
  end
end

return M
