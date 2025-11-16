-- lua/UEP/cmd/core/refresh_project.lua (N+1 fd最適化 ＆ 並列スケジュール版)
-- [!] "name too long" エラー修正版
-- [!] .uplugin のパース処理も vim.schedule を使った非同期ループに変更
-- [!] "attempt to call global '...' (a nil value)" エラー修正版

local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local fs = require("vim.fs")
local unl_analyzer = require("UNL.analyzer.build_cs")
local uep_graph = require("UEP.graph")
local uep_log = require("UEP.logger")
local project_cache = require("UEP.cache.project")
local uep_config = require("UEP.config")
local module_cache = require("UEP.cache.module")
local refresh_modules_core = require("UEP.cmd.core.refresh_modules")
local refresh_target_core = require("UEP.cmd.core.refresh_target")

local M = {}

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------
-- (get_name_from_root, parse_project_or_plugin_file, parse_component_build_cs_async は変更なし)
local function get_name_from_root(root_path)
  if not root_path then return nil end
  return unl_path.normalize(root_path):gsub("[\\/:]", "_")
end

local function parse_project_or_plugin_file(path)
  local log = uep_log.get()
  local json_string = table.concat(vim.fn.readfile(path), "")
  if vim.v.shell_error ~= 0 or json_string == "" then
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

local function parse_component_build_cs_async(component, build_cs_files, module_type_map, old_component_data, on_done)
  local log = uep_log.get()
  log.trace("parse_component_build_cs_async: Starting for '%s' with %d files.", component.display_name, #build_cs_files)
  
  local modules_meta = {}
  local source_mtimes = {}
  
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
  
  local i = 1
  local parse_loop
  parse_loop = function()
    if i > #build_cs_files then
      log.trace("Async parse loop for '%s' complete.", component.display_name)
      on_done(component.name, modules_meta, source_mtimes)
      return
    end
    
    local raw_path = build_cs_files[i]
    local build_cs_path = unl_path.normalize(raw_path)
    
    local current_mtime = vim.fn.getftime(build_cs_path)
    local old_mtime = (old_component_data and old_component_data.source_mtimes) and old_component_data.source_mtimes[build_cs_path] or -1
    local old_module_meta = old_modules_by_path_map[build_cs_path]

    if current_mtime == -1 then
      log.warn("Could not get mtime for %s. Skipping.", build_cs_path)
    
    elseif current_mtime == old_mtime and old_module_meta then
      modules_meta[old_module_meta.name] = old_module_meta
      source_mtimes[build_cs_path] = current_mtime
      
    else
      log.trace("Parsing changed file: %s", build_cs_path)
      
      local parse_ok, dependencies = pcall(unl_analyzer.parse, build_cs_path)
      if not parse_ok then
          log.error("Failed to parse Build.cs '%s': %s", build_cs_path, tostring(dependencies))
          dependencies = {}
      end
      
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
      
      modules_meta[module_name] = {
        name = module_name, path = build_cs_path, module_root = module_root,
        category = component.type, location = location, dependencies = dependencies,
        owner_name = component.owner_name,
        type = mod_type,
      }
      source_mtimes[build_cs_path] = current_mtime
    end
    
    i = i + 1
    vim.schedule(parse_loop)
  end
  
  log.trace("Starting async parse loop for %d files in '%s'...", #build_cs_files, component.display_name)
  parse_loop()
end

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

  -- (fd コマンド定義 ... 変更なし)
  local plugin_search_paths = {
    fs.joinpath(game_root, "Plugins"),
    fs.joinpath(engine_root, "Engine", "Plugins"),
    fs.joinpath(engine_root, "Engine", "Platforms"),
    fs.joinpath(engine_root, "Engine", "Source", "Developer")
  }
  local source_search_paths = {
    fs.joinpath(game_root, "Source"),
    fs.joinpath(game_root, "Programs"),
    fs.joinpath(engine_root, "Engine", "Source", "Runtime"),
    fs.joinpath(engine_root, "Engine", "Source", "Developer"),
    fs.joinpath(engine_root, "Engine", "Source", "Editor"),
    fs.joinpath(engine_root, "Engine", "Source", "Programs"),
    fs.joinpath(engine_root, "Engine", "Programs")
  }
  local fd_cmd_uplugin = { "fd", "--absolute-path", "--type", "f", "--path-separator", "/", "--glob", "*.uplugin" }
  for _, spath in ipairs(plugin_search_paths) do
      if vim.fn.isdirectory(spath) == 1 then
          table.insert(fd_cmd_uplugin, "--search-path")
          table.insert(fd_cmd_uplugin, spath)
      end
  end
  local fd_cmd_build_cs = { "fd", "--absolute-path", "--type", "f", "--path-separator", "/", "--regex", "\\.[Bb]uild\\.cs$" }
  for _, spath in ipairs(source_search_paths) do
    if vim.fn.isdirectory(spath) == 1 then
        table.insert(fd_cmd_build_cs, "--search-path")
        table.insert(fd_cmd_build_cs, spath)
    end
  end
  for _, spath in ipairs(plugin_search_paths) do
    if vim.fn.isdirectory(spath) == 1 then
        table.insert(fd_cmd_build_cs, "--search-path")
        table.insert(fd_cmd_build_cs, spath)
    end
  end
  
  -- (実行制御フラグ ... 変更なし)
  local jobs_running = 3
  local all_uplugin_files = {}
  local all_build_cs_files = {}
  local build_targets_list = nil
  local all_components = {}
  
  -- ▼▼▼【変更: 3つのフェーズ関数をここで宣言】▼▼▼
  local check_all_jobs_done
  local start_parallel_build_cs_parse
  local resolve_and_save_all
  -- ▲▲▲ 変更完了 ▲▲▲

  -- --------------------------------------------------
  -- フェーズ 1: fd ジョブの完了を待機
  -- --------------------------------------------------
  check_all_jobs_done = function(job_name)
    log.trace("Job finished: %s. Remaining jobs: %d", job_name, jobs_running)
    if jobs_running > 0 then return end
    log.debug("All initial fd jobs complete. Proceeding to parse plugin definitions (async)...")
    
    local files_to_parse_defs = { uproject_path }
    vim.list_extend(files_to_parse_defs, all_uplugin_files)
    
    local module_type_map = {}
    local files_total = #files_to_parse_defs
    local files_processed = 0
    
    local parse_defs_loop
    parse_defs_loop = function()
      files_processed = files_processed + 1
      
      if files_processed > files_total then
        log.info("Finished parsing %d project/plugin definitions.", files_total)
        
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
        
        local sorted_components = {}
        for _, c in ipairs(all_components) do table.insert(sorted_components, c) end
        table.sort(sorted_components, function(a, b) return #a.root_path > #b.root_path end)
        
        local files_by_component = {}
        for _, comp in ipairs(all_components) do
          files_by_component[comp.name] = {}
        end
        for _, file in ipairs(all_build_cs_files) do
          local file_normalized = unl_path.normalize(file)
          for _, comp in ipairs(sorted_components) do
            if file_normalized:find(unl_path.normalize(comp.root_path), 1, true) then
              table.insert(files_by_component[comp.name], file)
              break
            end
          end
        end
        log.debug("Mapped Build.cs files to %d components.", #all_components)

        -- [!] フェーズ 2 をキック
        start_parallel_build_cs_parse(
            all_components, 
            files_by_component, 
            module_type_map
        )
        return
      end
      
      local file_path = files_to_parse_defs[files_processed]
      local types = parse_project_or_plugin_file(file_path)
      if types then
        for name, type in pairs(types) do
          module_type_map[name] = type
        end
      end
      
      vim.schedule(parse_defs_loop)
    end
    
    log.info("Found %d .uplugin files. Parsing project and plugin definitions (async)...", #all_uplugin_files)
    parse_defs_loop()
    
  end

  -- --------------------------------------------------
  -- フェーズ 2: Build.cs の並列パース
  -- --------------------------------------------------
  start_parallel_build_cs_parse = function(
      _all_components, 
      _files_by_component, 
      _module_type_map
  )
    progress:stage_define("parse_components", #_all_components)
    progress:stage_update("parse_components", 0, "PASS 1: Parsing all Build.cs files (non-blocking)...")
    
    local components_remaining = #_all_components
    local raw_modules_by_component = {}
    local source_mtimes_by_component = {}
    
    local function on_component_parse_done(component_name, modules_meta, source_mtimes)
      raw_modules_by_component[component_name] = modules_meta
      source_mtimes_by_component[component_name] = source_mtimes
      components_remaining = components_remaining - 1
      
      progress:stage_update("parse_components", #_all_components - components_remaining, ("Parsed: %s [%d/%d]"):format(component_name, #_all_components - components_remaining, #_all_components))

      if components_remaining == 0 then
        log.debug("All component parsing scheduled jobs finished.")
        -- [!] フェーズ 3 をキック
        resolve_and_save_all(
          build_targets_list, 
          raw_modules_by_component, 
          source_mtimes_by_component,
          _all_components,
          _module_type_map,
          uproject_mtime
        )
      end
    end
    
    log.debug("Scheduling parallel parsing for %d components...", #_all_components)
    if #_all_components == 0 then
       log.warn("No components found. Aborting parse.")
       progress:stage_update("parse_components", 0, "No components found.")
       jobs_running = 0
       return 
    end
    
    for _, component in ipairs(_all_components) do
      local build_cs_for_this_comp = _files_by_component[component.name] or {}
      local cache_filename = component.name .. ".project.json"
      local old_data = project_cache.load(cache_filename)
      
      parse_component_build_cs_async(
        component,
        build_cs_for_this_comp,
        _module_type_map,
        old_data,
        on_component_parse_done
      )
    end
  end

  -- --------------------------------------------------
  -- フェーズ 3: 依存関係解決と保存 (最終処理)
  -- --------------------------------------------------
  resolve_and_save_all = function(
      parsed_build_targets, 
      _raw_modules_by_component, 
      _source_mtimes_by_component,
      _all_components,
      _module_type_map,
      _uproject_mtime
  )
    -- (この関数の内容は 300 行以上あり、変更はありません)
    -- (... 依存関係解決、キャッシュ保存、モジュールスキャン実行 ...)
    
    progress:stage_update("parse_components", #_all_components, "PASS 1 Complete. Aggregating modules...")
    
    -- 1. Parse 結果を集約
    local all_modules_meta_raw = {}
    for _, component_modules in pairs(_raw_modules_by_component) do
      for module_name, module_data in pairs(component_modules) do
        if not all_modules_meta_raw[module_name] or module_name == "Engine" then
            all_modules_meta_raw[module_name] = module_data
        else
            log.trace("Skipping duplicate module aggregation for '%s'", module_name)
        end
      end
    end
    log.debug("resolve_and_save_all: Aggregated %d raw modules (by name, pre-deps).", vim.tbl_count(all_modules_meta_raw))

    -- 2. 依存関係解決
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
    progress:stage_define("save_components", #_all_components)
    progress:stage_update("save_components", 0, "Saving/Loading component caches...")
    local result_data = { all_data = {}, changed_components = {}, full_component_list = _all_components }

    -- スコープに基づいて処理対象コンポーネントを決定
    local components_to_process = {}
    if refresh_opts.scope == "Game" then components_to_process = vim.tbl_filter(function(c) return c.owner_name == game_name end, _all_components)
    elseif refresh_opts.scope == "Engine" then components_to_process = vim.tbl_filter(function(c) return c.owner_name == engine_name end, _all_components)
    else components_to_process = _all_components end

    local processed_components = {}
    local current_progress_count = 0

    -- ループ 1: components_to_process (スコープ内のコンポーネント) を処理・保存
    for i, component in ipairs(components_to_process) do
      current_progress_count = current_progress_count + 1
      processed_components[component.name] = true

      local component_raw_modules = _raw_modules_by_component[component.name] or {}
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
      local source_mtimes = _source_mtimes_by_component[component.name] or {}
      source_mtimes[uproject_path] = _uproject_mtime
      
      local uplugin_path = component.type == "Plugin" and component.uplugin_path or nil

      local new_data = {
        name = component.name, display_name = component.display_name, type = component.type,
        root_path = component.root_path, owner_name = component.owner_name,
        uplugin_path = uplugin_path,
        generation = new_generation, source_mtimes = source_mtimes,
        runtime_modules = runtime_modules, developer_modules = developer_modules,
        editor_modules = editor_modules, programs_modules = programs_modules,
        build_targets = (component.type == "Game") and parsed_build_targets or nil,
      }

      local cache_filename = component.name .. ".project.json"
      local old_data = project_cache.load(cache_filename)
      local has_changed = false
      
      if refresh_opts.force then has_changed = true; log.info("Forced update for component: %s", component.display_name)
      elseif not old_data then has_changed = true
      elseif old_data.generation ~= new_generation then
        has_changed = true
      end

      if has_changed then
        log.trace("Updating project cache for component: %s (gen: %s)", component.display_name, new_generation:sub(1,8))
        project_cache.save(cache_filename, new_data)
        table.insert(result_data.changed_components, new_data)
      end
      result_data.all_data[component.name] = has_changed and new_data or old_data
      progress:stage_update("save_components", current_progress_count, ("Processed: %s [%d/%d]"):format(component.display_name, current_progress_count, #_all_components))
    end

    -- ループ 2: スコープ外のコンポーネントのキャッシュをロード
    for i, component in ipairs(_all_components) do
        if not processed_components[component.name] then
            current_progress_count = current_progress_count + 1
            local cache_filename = component.name .. ".project.json"
            local old_data = project_cache.load(cache_filename)
            if old_data then
                result_data.all_data[component.name] = old_data
                progress:stage_update("save_components", current_progress_count, ("Loaded cache: %s [%d/%d]"):format(component.display_name, current_progress_count, #_all_components))
            else
                log.warn("resolve_and_save_all: Cache missing for out-of-scope component '%s'. This component's modules will be ignored.", component.display_name)
                progress:stage_update("save_components", current_progress_count, ("Cache missing: %s [%d/%d]"):format(component.display_name, current_progress_count, #_all_components))
            end
        end
    end

    -- (モジュールキャッシュ更新対象決定ロジック ... 変更なし)
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
    
    -- (モジュールキャッシュスキャン実行 ... 変更なし)
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

  
  -- --------------------------------------------------
  -- 起動トリガー: 3つのジョブを並列で起動
  -- --------------------------------------------------
  
  -- 1. Target.cs 検索 (非同期)
  refresh_target_core.find_and_parse_targets_async(game_root, engine_root, function(parsed_targets)
    log.debug("Target.cs scan finished.")
    build_targets_list = parsed_targets or {}
    jobs_running = jobs_running - 1
    check_all_jobs_done("Target.cs")
  end)

  -- 2. .uplugin 検索 (非同期)
  local uplugin_fd_stderr = {}
  vim.fn.jobstart(fd_cmd_uplugin, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_uplugin_files, line) end end end
    end,
    on_stderr = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(uplugin_fd_stderr, line) end end end
    end,
    on_exit = function(_, uplugin_code)
      if uplugin_code ~= 0 then
         log.error("fd command failed for uplugins: %s", table.concat(uplugin_fd_stderr, "\n"))
      end
      log.debug(".uplugin scan finished. Found %d files.", #all_uplugin_files)
      jobs_running = jobs_running - 1
      check_all_jobs_done(".uplugin")
    end,
  })
  
  -- 3. Build.cs 検索 (非同期)
  local build_cs_fd_stderr = {}
  vim.fn.jobstart(fd_cmd_build_cs, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_build_cs_files, line) end end end
    end,
    on_stderr = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(build_cs_fd_stderr, line) end end end
    end,
    on_exit = function(_, build_cs_code)
      if build_cs_code ~= 0 then
         log.error("fd command failed for Build.cs: %s", table.concat(build_cs_fd_stderr, "\n"))
      end
      log.debug("Build.cs scan finished. Found %d files.", #all_build_cs_files)
      jobs_running = jobs_running - 1
      check_all_jobs_done("Build.cs")
    end,
  })
  
end -- M.update_project_structure 終わり

return M
