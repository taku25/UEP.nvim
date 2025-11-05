-- lua/UEP/cmd/core/refresh_project.lua (最適化版: mtime差分更新 + vim.schedule非同期ループ)

local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local fs = require("vim.fs")
local unl_analyzer = require("UNL.analyzer.build_cs") -- [!] 逐次版ではこちらが require する
local uep_graph = require("UEP.graph")
local uep_log = require("UEP.logger")
local project_cache = require("UEP.cache.project")
local uep_config = require("UEP.config")
local module_cache = require("UEP.cache.module")
local refresh_modules_core = require("UEP.cmd.core.refresh_modules")

local M = {}

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------
local function get_name_from_root(root_path)
  if not root_path then return nil end
  return unl_path.normalize(root_path):gsub("[\\/:]", "_")
end

local function parse_project_or_plugin_file(path)
  local log = uep_log.get()
  local json_string = table.concat(vim.fn.readfile(path), "")
  if vim.v.shell_error ~= 0 or json_string == "" then
    -- log.warn("Could not read project/plugin file: %s", path)
    return nil
  end

  local ok, data = pcall(vim.json.decode, json_string)
  if not ok or not data or not data.Modules or type(data.Modules) ~= "table" then
    return nil
  end

  local type_map = {}
  for _, module_info in ipairs(data.Modules) do
    if module_info.Name and module_info.Type then
      type_map[module_info.Name] = module_info.Type
    end
  end
  return type_map
end

-- ▼▼▼ [修正] 最適化版 parse_single_component ▼▼▼
---
-- 1コンポーネントの Build.cs を非同期で検索・パースする
-- mtime を比較し、変更がないファイルはパースをスキップする
-- vim.schedule を使い、メインスレッドをブロックしない
--
-- @param component table
-- @param module_type_map table
-- @param old_component_data table|nil 前回のキャッシュデータ
-- @param on_done function(ok, { meta = {}, mtimes = {} })
local function parse_single_component(component, module_type_map, old_component_data, on_done)
  local log = uep_log.get()
  local search_paths = {}

  -- 1. 検索パスの決定 (変更なし)
  if component.type == "Engine" then
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Source", "Runtime"))
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Source", "Developer"))
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Source", "Editor"))
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Source", "Programs"))
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Programs"))
  elseif component.type == "Game" then
    table.insert(search_paths, fs.joinpath(component.root_path, "Source"))
    table.insert(search_paths, fs.joinpath(component.root_path, "Programs"))
  else -- Plugin の場合
    table.insert(search_paths, component.root_path)
  end

  if #search_paths == 0 then
    on_done(true, { meta = {}, mtimes = {} })
    return
  end
  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "--regex", "\\.[Bb]uild\\.cs$" }
  for _, spath in ipairs(search_paths) do
    if vim.fn.isdirectory(spath) == 1 then
        table.insert(fd_cmd, "--search-path")
        table.insert(fd_cmd, spath)
    end
  end
  
  -- 2. fd で Build.cs を非同期検索 (変更なし)
  local build_cs_files = {}
  local fd_stderr = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(build_cs_files, line) end end end
    end,
    on_stderr = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(fd_stderr, line) end end end
    end,
    on_exit = function(_, code) -- [!] fd 完了時のコールバック
      log.trace("parse_single_component: fd command for '%s' finished with code %d. Found %d Build.cs files.",
                component.display_name, code, #build_cs_files)
      if code ~= 0 then
         log.error("fd command failed for '%s': %s", component.display_name, table.concat(fd_stderr, "\n"))
         -- fdが失敗しても、空の結果で on_done を呼び、処理は続行する
      end

      local modules_meta = {} -- このコンポーネントの全モジュールメタデータ
      local source_mtimes = {} -- このコンポーネントの全 .cs の mtime
      
      -- 3. [新規] 古いキャッシュからモジュールマップを作成 (mtime比較用)
      local old_modules_by_path_map = {}
      if old_component_data then
        for _, mtype in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do
          if old_component_data[mtype] then
            for mod_name, mod_data in pairs(old_component_data[mtype]) do
              if mod_data.path then
                old_modules_by_path_map[mod_data.path] = mod_data
              end
            end
          end
        end
      end
      
      -- 4. [新規] vim.schedule を使った非同期ループ
      local i = 1
      local parse_loop
      parse_loop = function()
        -- a. ベースケース: 全ファイルの処理が完了
        if i > #build_cs_files then
          log.debug("Async parse loop for '%s' complete.", component.display_name)
          on_done(true, { meta = modules_meta, mtimes = source_mtimes })
          return
        end
        
        -- b. 1ファイル取得
        local raw_path = build_cs_files[i]
        local build_cs_path = unl_path.normalize(raw_path)
        
        -- c. mtime 比較
        local current_mtime = vim.fn.getftime(build_cs_path)
        local old_mtime = (old_component_data and old_component_data.source_mtimes) and old_component_data.source_mtimes[build_cs_path] or -1
        local old_module_meta = old_modules_by_path_map[build_cs_path]

        if current_mtime == -1 then -- ファイルが読めない
          log.warn("Could not get mtime for %s. Skipping.", build_cs_path)
        
        elseif current_mtime == old_mtime and old_module_meta then
          -- [最適化 1] mtime が同じ ＝ スキップ
          -- 古いデータをそのままコピー
          modules_meta[old_module_meta.name] = old_module_meta
          source_mtimes[build_cs_path] = current_mtime
          
        else
          -- [変更あり] mtime が異なる、または新規ファイル ＝ パース実行
          log.trace("Parsing changed file: %s", build_cs_path)
          
          -- [!] parse は同期的だが、1ファイルだけなので高速
          local parse_ok, dependencies = pcall(unl_analyzer.parse, build_cs_path)
          if not parse_ok then
              log.error("Failed to parse Build.cs '%s': %s", build_cs_path, tostring(dependencies))
              dependencies = {}
          end
          
          -- (型決定ロジック - 変更なし)
          local module_name = vim.fn.fnamemodify(build_cs_path, ":t:r:r")
          local module_root = vim.fn.fnamemodify(build_cs_path, ":h")
          local location = build_cs_path:find("/Plugins/", 1, true) and "in_plugins" or "in_source"
          local mod_type = module_type_map[module_name]
          local type_source = "None"
          if mod_type then type_source = "Plugin/Project File"
          else
            local lower_path = build_cs_path:lower()
            if lower_path:find("/programs/", 1, true) then mod_type = "Program"; type_source = "Path (Programs)"
            elseif lower_path:find("/engine/source/runtime/", 1, true) then mod_type = "Runtime"; type_source = "Path (Runtime)"
            elseif lower_path:find("/engine/source/developer/", 1, true) then mod_type = "Developer"; type_source = "Path (Developer)"
            elseif lower_path:find("/engine/source/editor/", 1, true) then mod_type = "Editor"; type_source = "Path (Editor)"
            elseif component.type == "Game" and location == "in_source" then mod_type = "Runtime"; type_source = "Path (Game Source)" end
          end
          if not mod_type then mod_type = "Runtime"; type_source = "Default (Runtime)" end
          
          -- 新しいメタデータを保存
          modules_meta[module_name] = {
            name = module_name, path = build_cs_path, module_root = module_root,
            category = component.type, location = location, dependencies = dependencies,
            owner_name = component.owner_name,
            type = mod_type,
          }
          source_mtimes[build_cs_path] = current_mtime
        end
        
        -- d. [最適化 2] 次のファイルの処理をスケジュール
        i = i + 1
        vim.schedule(parse_loop)
      end
      
      -- 5. [新規] 非同期ループの開始
      log.debug("Starting async parse loop for %d files in '%s'...", #build_cs_files, component.display_name)
      parse_loop() -- i = 1 で開始
    end,
  })
end
-- ▲▲▲ 最適化版 parse_single_component 完了 ▲▲▲

-------------------------------------------------
-- メインAPI
-------------------------------------------------
function M.update_project_structure(refresh_opts, uproject_path, progress, on_done)
  local log = uep_log.get()
  local game_root = vim.fn.fnamemodify(uproject_path, ":h")
  local engine_root = unl_finder.engine.find_engine_root(uproject_path, {
    engine_override_path = uep_config.get().engine_path,
  })
  if not engine_root then
    log.error("update_project_structure: Could not find engine root.")
    return on_done(false, "Could not find engine root.")
  end

  local game_name = get_name_from_root(game_root)
  local engine_name = get_name_from_root(engine_root)
  local uproject_mtime = vim.fn.getftime(uproject_path)

  -- .uplugin 検索 (変更なし)
  local plugin_search_paths = {
    fs.joinpath(game_root, "Plugins"),
    fs.joinpath(engine_root, "Engine", "Plugins"),
    fs.joinpath(engine_root, "Engine", "Platforms"),
    fs.joinpath(engine_root, "Engine", "Source", "Developer")
  }
  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "--path-separator", "/", "--glob", "*.uplugin" }
  for _, spath in ipairs(plugin_search_paths) do
      if vim.fn.isdirectory(spath) == 1 then
          table.insert(fd_cmd, "--search-path")
          table.insert(fd_cmd, spath)
      end
  end

  local all_uplugin_files = {}
  local uplugin_fd_stderr = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_uplugin_files, line) end end end
    end,
    on_stderr = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(uplugin_fd_stderr, line) end end end
    end,
    on_exit = function(_, uplugin_code) -- .uplugin 検索の on_exit コールバック
      if uplugin_code ~= 0 then
         log.error("fd command failed for uplugins: %s", table.concat(uplugin_fd_stderr, "\n"))
      end

      -- .uproject/.uplugin を先に解析 (変更なし)
      log.info("Found %d .uplugin files. Parsing project and plugin definitions...", #all_uplugin_files)
      local module_type_map = {}
      local uproject_types = parse_project_or_plugin_file(uproject_path)
      if uproject_types then for name, type in pairs(uproject_types) do module_type_map[name] = type end end
      for _, uplugin_path in ipairs(all_uplugin_files) do
        local uplugin_types = parse_project_or_plugin_file(uplugin_path)
        if uplugin_types then for name, type in pairs(uplugin_types) do module_type_map[name] = type end end
      end
      log.info("Finished parsing. Found type definitions for %d modules.", vim.tbl_count(module_type_map))

      -- all_components リスト作成 (変更なし)
      local all_components = {}
      table.insert(all_components, { name = game_name, display_name = vim.fn.fnamemodify(game_root, ":t"), type = "Game", root_path = game_root, owner_name = game_name })
      table.insert(all_components, { name = engine_name, display_name = "Engine", type = "Engine", root_path = engine_root, owner_name = engine_name })
      for _, uplugin_path in ipairs(all_uplugin_files) do
        local plugin_root = vim.fn.fnamemodify(uplugin_path, ":h")
        local owner_name = uplugin_path:find(engine_root, 1, true) and engine_name or game_name
        table.insert(all_components, {
            name = get_name_from_root(plugin_root),
            display_name = vim.fn.fnamemodify(uplugin_path, ":t:r"),
            type = "Plugin",
            root_path = plugin_root,
            owner_name = owner_name,
            uplugin_path = uplugin_path
        })
      end

      -- スコープに基づいて処理対象コンポーネントを決定 (変更なし)
      local components_to_process = {}
      if refresh_opts.scope == "Game" then components_to_process = vim.tbl_filter(function(c) return c.owner_name == game_name end, all_components)
      elseif refresh_opts.scope == "Engine" then components_to_process = vim.tbl_filter(function(c) return c.owner_name == engine_name end, all_components)
      else components_to_process = all_components end

      -- ▼▼▼ [修正] Build.cs パースループ開始 (逐次版) ▼▼▼
      progress:stage_define("parse_components", #all_components)
      progress:stage_update("parse_components", 0, "PASS 1: Parsing all Build.cs files (non-blocking)...")
      local raw_modules_by_component = {}
      local source_mtimes_by_component = {}
      local current_index = 0
      local resolve_and_save_all -- 最終コールバックを先に宣言

      -- 逐次処理用の `parse_next` 関数
      local function parse_next()
        current_index = current_index + 1
        -- 1. 全コンポーネントが完了したら、最終処理へ
        if current_index > #all_components then
          resolve_and_save_all()
          return
        end
        
        -- 2. 次のコンポーネントを処理
        local component = all_components[current_index]
        
        -- [!] 古いキャッシュをここでロード
        local cache_filename = component.name .. ".project.json"
        local old_data = project_cache.load(cache_filename)
        
        -- [!] `old_data` を `parse_single_component` に渡す
        parse_single_component(component, module_type_map, old_data, function(ok, result)
          if ok then
            raw_modules_by_component[component.name] = result.meta
            source_mtimes_by_component[component.name] = result.mtimes
            progress:stage_update("parse_components", current_index, ("Parsed: %s [%d/%d]"):format(component.display_name, current_index, #all_components))
            
            -- 3. 処理が終わったら、次のコンポーネントを処理するために自分を呼び出す
            vim.schedule(parse_next)
          else
            log.error("Failed to parse component '%s'. Aborting refresh.", component.display_name)
            on_done(false, "Failed to parse component.")
          end
        end)
      end

      -- 依存関係解決と保存 (最終コールバック)
      resolve_and_save_all = function()
        progress:stage_update("parse_components", #all_components, "PASS 1 Complete. Aggregating modules...")
        
        -- 1. Parse 結果を集約 (変更なし)
        local all_modules_meta_raw = {}
        for _, component_modules in pairs(raw_modules_by_component) do
          for module_name, module_data in pairs(component_modules) do
            if not all_modules_meta_raw[module_name] or module_name == "Engine" then
                all_modules_meta_raw[module_name] = module_data
            else
                log.trace("Skipping duplicate module aggregation for '%s'", module_name)
            end
          end
        end
        log.debug("resolve_and_save_all: Aggregated %d raw modules (by name, pre-deps).", vim.tbl_count(all_modules_meta_raw))

        -- 2. 依存関係解決 (変更なし)
        progress:stage_define("resolve_deps", 1)
        progress:stage_update("resolve_deps", 0, "PASS 2: Resolving all dependencies...")
        local resolve_ok, full_dependency_map_or_err = pcall(uep_graph.resolve_all_dependencies, all_modules_meta_raw)
        if not resolve_ok then
            log.error("Failed to resolve dependencies: %s", tostring(full_dependency_map_or_err))
            return on_done(false, "Failed dependency resolution.")
        end
        local full_dependency_map = full_dependency_map_or_err
        progress:stage_update("resolve_deps", 1, "Dependency resolution complete.")
        log.debug("resolve_and_save_all: Resolved dependencies for %d modules (by name).", vim.tbl_count(full_dependency_map))

        -- 3. 構造キャッシュ保存ループ
        progress:stage_define("save_components", #all_components)
        progress:stage_update("save_components", 0, "Saving/Loading component caches...")
        local result_data = { all_data = {}, changed_components = {}, full_component_list = all_components }

        local processed_components = {}
        local current_progress_count = 0

        -- ループ 1: components_to_process (スコープ内のコンポーネント) を処理・保存
        for i, component in ipairs(components_to_process) do
          current_progress_count = current_progress_count + 1
          processed_components[component.name] = true

          local component_raw_modules = raw_modules_by_component[component.name] or {}
          local runtime_modules, developer_modules, editor_modules, programs_modules = {}, {}, {}, {}

          for module_name, _ in pairs(component_raw_modules) do
            if full_dependency_map[module_name] then
              local mod_meta = full_dependency_map[module_name]
              local mod_type = mod_meta.type
              if mod_type then
                local clean_type_lower = mod_meta.type:match("^%s*(.-)%s*$"):lower()
                if clean_type_lower == "program" then programs_modules[module_name] = mod_meta
                elseif clean_type_lower == "developer" then developer_modules[module_name] = mod_meta
                elseif clean_type_lower:find("editor", 1, true) or clean_type_lower == "uncookedonly" then editor_modules[module_name] = mod_meta
                else runtime_modules[module_name] = mod_meta end
              else runtime_modules[module_name] = mod_meta end
            end
          end

          local content_to_hash = vim.json.encode({ r = runtime_modules, d = developer_modules, e = editor_modules, p = programs_modules })
          local new_generation = vim.fn.sha256(content_to_hash)
          local source_mtimes = source_mtimes_by_component[component.name] or {}
          source_mtimes[uproject_path] = uproject_mtime
          
          local uplugin_path = component.type == "Plugin" and component.uplugin_path or nil

          local new_data = {
            name = component.name, display_name = component.display_name, type = component.type,
            root_path = component.root_path, owner_name = component.owner_name,
            uplugin_path = uplugin_path,
            generation = new_generation, source_mtimes = source_mtimes,
            runtime_modules = runtime_modules, developer_modules = developer_modules,
            editor_modules = editor_modules, programs_modules = programs_modules,
          }

          local cache_filename = component.name .. ".project.json"
          local old_data = project_cache.load(cache_filename)
          local has_changed = false
          
          -- ▼▼▼ [修正] 古い mtime チェック (cache_is_stale) を削除 ▼▼▼
          -- `parse_single_component` が差分更新したので、`generation` の比較だけで十分
          if refresh_opts.force then has_changed = true; log.info("Forced update for component: %s", component.display_name)
          elseif not old_data then has_changed = true
          elseif old_data.generation ~= new_generation then
            has_changed = true
          end
          -- ▲▲▲ 修正完了 ▲▲▲

          if has_changed then
            log.info("Updating project cache for component: %s (gen: %s)", component.display_name, new_generation:sub(1,8))
            project_cache.save(cache_filename, new_data)
            table.insert(result_data.changed_components, new_data)
          end
          result_data.all_data[component.name] = has_changed and new_data or old_data
          progress:stage_update("save_components", current_progress_count, ("Processed: %s [%d/%d]"):format(component.display_name, current_progress_count, #all_components))
        end

        -- ループ 2: スコープ外のコンポーネントのキャッシュをロード (変更なし)
        for i, component in ipairs(all_components) do
            if not processed_components[component.name] then
                current_progress_count = current_progress_count + 1
                local cache_filename = component.name .. ".project.json"
                local old_data = project_cache.load(cache_filename)
                if old_data then
                    result_data.all_data[component.name] = old_data
                    progress:stage_update("save_components", current_progress_count, ("Loaded cache: %s [%d/%d]"):format(component.display_name, current_progress_count, #all_components))
                else
                    log.warn("resolve_and_save_all: Cache missing for out-of-scope component '%s'. This component's modules will be ignored.", component.display_name)
                    progress:stage_update("save_components", current_progress_count, ("Cache missing: %s [%d/%d]"):format(component.display_name, current_progress_count, #all_components))
                end
            end
        end

        -- モジュールキャッシュ更新対象決定 (変更なし)
        local all_modules_meta_map_by_path = {}
        log.debug("resolve_and_save_all: Aggregating all modules by path for module cache scan...")
        for comp_name, component_data in pairs(result_data.all_data) do
            for _, type_key in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do
                if component_data[type_key] then
                    for mod_name, mod_data in pairs(component_data[type_key]) do
                        if mod_data and mod_data.module_root then
                            if not all_modules_meta_map_by_path[mod_data.module_root] then
                                all_modules_meta_map_by_path[mod_data.module_root] = mod_data
                            end
                        end
                    end
                end
            end
        end
        log.debug("resolve_and_save_all: Aggregated %d unique modules by path.", vim.tbl_count(all_modules_meta_map_by_path))

        local modules_to_scan_meta = {}
        if refresh_opts.bang or refresh_opts.force then
          log.info("Bang(!) or --force specified. All modules in scope '%s' will be scanned.", refresh_opts.scope or "Full")
          if refresh_opts.scope == "Full" or not refresh_opts.scope then
            modules_to_scan_meta = all_modules_meta_map_by_path
          else
            local owner_name_to_match = (refresh_opts.scope == "Engine" and engine_name) or game_name
            for path, mod_meta in pairs(all_modules_meta_map_by_path) do 
              if mod_meta.owner_name == owner_name_to_match then modules_to_scan_meta[path] = mod_meta end
            end
          end
        else
          local function add_module_to_scan_list(mod_meta)
              if mod_meta and mod_meta.module_root and not modules_to_scan_meta[mod_meta.module_root] then
                  modules_to_scan_meta[mod_meta.module_root] = mod_meta
              end
          end
          for _, c in ipairs(result_data.changed_components) do
            if c.runtime_modules then for _, mm in pairs(c.runtime_modules) do add_module_to_scan_list(mm) end end
            if c.developer_modules then for _, mm in pairs(c.developer_modules) do add_module_to_scan_list(mm) end end
            if c.editor_modules then for _, mm in pairs(c.editor_modules) do add_module_to_scan_list(mm) end end
            if c.programs_modules then for _, mm in pairs(c.programs_modules) do add_module_to_scan_list(mm) end end
          end
          for path, mod_meta in pairs(all_modules_meta_map_by_path) do 
            if not modules_to_scan_meta[path] then
              if not module_cache.load(mod_meta) then
                log.info("Module cache for '%s' (at %s) not found. Adding to scan queue.", mod_meta.name, path)
                add_module_to_scan_list(mod_meta)
              end
            end
          end
        end
        
        local modules_to_scan_count = vim.tbl_count(modules_to_scan_meta)
        log.debug("resolve_and_save_all: Determined %d modules to scan.", modules_to_scan_count)
        
        -- モジュールキャッシュスキャン実行 (変更なし)
        if modules_to_scan_count > 0 or (refresh_opts.bang or refresh_opts.force) then
          log.info("Starting file scan for %d module(s) (and component roots)...", modules_to_scan_count)
          refresh_modules_core.create_module_caches_for(
            modules_to_scan_meta,
            all_modules_meta_map_by_path,
            result_data.all_data,
            progress,
            game_root, engine_root,
            function(files_ok)
                if not files_ok then log.error("Module file cache generation failed.") end
                on_done(files_ok, result_data)
            end
          )
        else
          log.info("Project structure is up-to-date and all module caches exist. Nothing to refresh.")
          on_done(true, result_data)
        end

      end -- resolve_and_save_all 終わり

      -- [!] 逐次処理の最初の呼び出し
      parse_next()
      -- ▲▲▲ 変更完了 ▲▲▲

    end, -- .uplugin 検索 on_exit 終わり
  }) -- .uplugin 検索 jobstart 終わり
end -- M.update_project_structure 終わり

return M
