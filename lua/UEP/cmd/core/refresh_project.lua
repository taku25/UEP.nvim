-- lua/UEP/cmd/core/refresh_project.lua (完全版 - :t:r:r 修正 + all_components_map 渡し + スコープ外キャッシュロード修正)

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

-- ▼▼▼ parse_single_component (":t:r:r" 修正版) ▼▼▼
local function parse_single_component(component, module_type_map, on_done)
  local log = uep_log.get()
  local search_paths = {}

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
    -- 検索パスが存在するか確認してから追加
    if vim.fn.isdirectory(spath) == 1 then
        table.insert(fd_cmd, "--search-path")
        table.insert(fd_cmd, spath)
    end
  end
  log.trace("parse_single_component: Executing fd command for '%s': %s", component.display_name, vim.inspect(fd_cmd))

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
    on_exit = function(_, code)
      log.trace("parse_single_component: fd command for '%s' finished with code %d. Found %d Build.cs files.",
                component.display_name, code, #build_cs_files)
      if code ~= 0 then
         log.error("fd command failed for '%s': %s", component.display_name, table.concat(fd_stderr, "\n"))
      end

      local modules_meta = {}
      local source_mtimes = {}
      if #build_cs_files > 0 then
        for i, raw_path in ipairs(build_cs_files) do
          local build_cs_path = unl_path.normalize(raw_path)
          log.trace("parse_single_component: Processing Build.cs [%d/%d] for '%s': %s",
                    i, #build_cs_files, component.display_name, build_cs_path)

          if vim.fn.filereadable(build_cs_path) == 0 then
              goto continue
          end

          source_mtimes[build_cs_path] = vim.fn.getftime(build_cs_path)
          
          -- ★★★ モジュール名取得を ":t:r:r" に修正 ★★★
          local module_name = vim.fn.fnamemodify(build_cs_path, ":t:r:r")
          
          local module_root = vim.fn.fnamemodify(build_cs_path, ":h")
          local location = build_cs_path:find("/Plugins/", 1, true) and "in_plugins" or "in_source"

          local parse_ok, dependencies = pcall(unl_analyzer.parse, build_cs_path)
          if not parse_ok then
              log.error("parse_single_component: Failed to parse Build.cs '%s': %s", build_cs_path, tostring(dependencies))
              dependencies = {}
          end

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

          log.trace("Module Type Determination: Name=%s, Type=%s, Source=%s (Path: %s)",
                   module_name, mod_type, type_source, build_cs_path)

          modules_meta[module_name] = {
            name = module_name, path = build_cs_path, module_root = module_root,
            category = component.type, location = location, dependencies = dependencies,
            owner_name = component.owner_name,
            type = mod_type,
          }
          ::continue::
        end
      end
      on_done(true, { meta = modules_meta, mtimes = source_mtimes })
    end,
  })
end
-- ▲▲▲ parse_single_component 修正ここまで ▲▲▲

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

  -- .uplugin 検索
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
    on_exit = function(_, uplugin_code)
      if uplugin_code ~= 0 then
         log.error("fd command failed for uplugins: %s", table.concat(uplugin_fd_stderr, "\n"))
      end

      -- .uproject/.uplugin を先に解析
      log.info("Found %d .uplugin files. Parsing project and plugin definitions...", #all_uplugin_files)
      local module_type_map = {}
      local uproject_types = parse_project_or_plugin_file(uproject_path)
      if uproject_types then for name, type in pairs(uproject_types) do module_type_map[name] = type end end
      for _, uplugin_path in ipairs(all_uplugin_files) do
        local uplugin_types = parse_project_or_plugin_file(uplugin_path)
        if uplugin_types then for name, type in pairs(uplugin_types) do module_type_map[name] = type end end
      end
      log.info("Finished parsing. Found type definitions for %d modules.", vim.tbl_count(module_type_map))

      -- all_components リスト作成
      local all_components = {}
      table.insert(all_components, { name = game_name, display_name = vim.fn.fnamemodify(game_root, ":t"), type = "Game", root_path = game_root, owner_name = game_name })
      table.insert(all_components, { name = engine_name, display_name = "Engine", type = "Engine", root_path = engine_root, owner_name = engine_name })
      for _, uplugin_path in ipairs(all_uplugin_files) do
        local plugin_root = vim.fn.fnamemodify(uplugin_path, ":h")
        local owner_name = uplugin_path:find(engine_root, 1, true) and engine_name or game_name
        -- ★ .uplugin パスもコンポーネント情報に含める
        table.insert(all_components, {
            name = get_name_from_root(plugin_root),
            display_name = vim.fn.fnamemodify(uplugin_path, ":t:r"),
            type = "Plugin",
            root_path = plugin_root,
            owner_name = owner_name,
            uplugin_path = uplugin_path -- ★ 追加
        })
      end

      -- スコープに基づいて処理対象コンポーネントを決定
      local components_to_process = {}
      if refresh_opts.scope == "Game" then components_to_process = vim.tbl_filter(function(c) return c.owner_name == game_name end, all_components)
      elseif refresh_opts.scope == "Engine" then components_to_process = vim.tbl_filter(function(c) return c.owner_name == engine_name end, all_components)
      else components_to_process = all_components end

      -- Build.cs パースループ開始
      progress:stage_define("parse_components", #all_components)
      progress:stage_update("parse_components", 0, "PASS 1: Parsing all Build.cs files...")
      local raw_modules_by_component = {}
      local source_mtimes_by_component = {}
      local current_index = 0
      local resolve_and_save_all

      local function parse_next()
        current_index = current_index + 1
        if current_index > #all_components then
          resolve_and_save_all()
          return
        end
        local component = all_components[current_index]
        parse_single_component(component, module_type_map, function(ok, result)
          if ok then
            raw_modules_by_component[component.name] = result.meta
            source_mtimes_by_component[component.name] = result.mtimes
            progress:stage_update("parse_components", current_index, ("Parsed: %s [%d/%d]"):format(component.display_name, current_index, #all_components))
            vim.schedule(parse_next)
          else
            log.error("Failed to parse component '%s'. Aborting refresh.", component.display_name)
            on_done(false, "Failed to parse component.")
          end
        end)
      end

      -- 依存関係解決と保存
      resolve_and_save_all = function()
        progress:stage_update("parse_components", #all_components, "PASS 1 Complete. Aggregating modules...")

        -- 1. Parse 結果を集約 (キーはモジュール名)
        local all_modules_meta_raw = {}
        for _, component_modules in pairs(raw_modules_by_component) do
          for module_name, module_data in pairs(component_modules) do
            -- ★ 衝突スキップロジック (Engine優先)
            if not all_modules_meta_raw[module_name] or module_name == "Engine" then
                all_modules_meta_raw[module_name] = module_data
            else
                log.trace("Skipping duplicate module aggregation for '%s'", module_name)
            end
          end
        end
        log.debug("resolve_and_save_all: Aggregated %d raw modules (by name, pre-deps).", vim.tbl_count(all_modules_meta_raw))

        -- 2. 依存関係解決 (キーはモジュール名)
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
        progress:stage_define("save_components", #all_components) -- [!] プログレスの最大値を all_components に変更
        progress:stage_update("save_components", 0, "Saving/Loading component caches...") -- [!] メッセージ変更
        local result_data = { all_data = {}, changed_components = {}, full_component_list = all_components }

        -- [!] 処理済みコンポーネントを追跡するマップ
        local processed_components = {}
        local current_progress_count = 0

        -- ループ 1: components_to_process (スコープ内のコンポーネント) を処理・保存
        for i, component in ipairs(components_to_process) do
          current_progress_count = current_progress_count + 1 -- [!] カウンタをインクリメント
          processed_components[component.name] = true -- [!] 処理済みフラグ

          local component_raw_modules = raw_modules_by_component[component.name] or {}
          local runtime_modules, developer_modules, editor_modules, programs_modules = {}, {}, {}, {}

          for module_name, _ in pairs(component_raw_modules) do
            if full_dependency_map[module_name] then
              local mod_meta = full_dependency_map[module_name]
              local mod_type = mod_meta.type
              if mod_type then
                local clean_type_lower = mod_type:match("^%s*(.-)%s*$"):lower()
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
          
          -- ★ .uplugin パスもキャッシュに保存
          local uplugin_path = component.type == "Plugin" and component.uplugin_path or nil

          local new_data = {
            name = component.name, display_name = component.display_name, type = component.type,
            root_path = component.root_path, owner_name = component.owner_name,
            uplugin_path = uplugin_path, -- ★ 追加
            generation = new_generation, source_mtimes = source_mtimes,
            runtime_modules = runtime_modules, developer_modules = developer_modules,
            editor_modules = editor_modules, programs_modules = programs_modules,
          }

          local cache_filename = component.name .. ".project.json"
          local old_data = project_cache.load(cache_filename)
          local has_changed = false
          if refresh_opts.force then has_changed = true; log.info("Forced update for component: %s", component.display_name)
          elseif not old_data then has_changed = true
          elseif refresh_opts.bang then has_changed = (old_data.generation ~= new_generation)
          else
            local cache_is_stale = false
            if old_data.source_mtimes then
              for path, old_mtime in pairs(old_data.source_mtimes) do
                local current_mtime = vim.fn.getftime(path)
                if (vim.fn.filereadable(path) == 0) or (current_mtime == -1) or (current_mtime > old_mtime) then
                  cache_is_stale = true; break
                end
              end
            else cache_is_stale = true end
            if cache_is_stale then has_changed = (old_data.generation ~= new_generation) end
          end

          if has_changed then
            log.info("Updating project cache for component: %s (gen: %s)", component.display_name, new_generation:sub(1,8))
            project_cache.save(cache_filename, new_data)
            table.insert(result_data.changed_components, new_data)
          end
          result_data.all_data[component.name] = has_changed and new_data or old_data
          progress:stage_update("save_components", current_progress_count, ("Processed: %s [%d/%d]"):format(component.display_name, current_progress_count, #all_components)) -- [!] プログレス更新
        end

        -- ▼▼▼ 【修正箇所】 ▼▼▼
        -- ループ 2: スコープ外のコンポーネントのキャッシュをロード
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
        -- ▲▲▲ 【修正完了】 ▲▲▲

        -- ▼▼▼ モジュールキャッシュ更新対象決定 (キーをパスに変更) ▼▼▼
        local all_modules_meta_map_by_path = {}
        log.debug("resolve_and_save_all: Aggregating all modules by path for module cache scan...")
        local modules_missing_root = 0
        for comp_name, component_data in pairs(result_data.all_data) do
            for _, type_key in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do
                if component_data[type_key] then
                    for mod_name, mod_data in pairs(component_data[type_key]) do
                        if mod_data and mod_data.module_root then
                            -- ★ キーを module_root に変更
                            if not all_modules_meta_map_by_path[mod_data.module_root] then
                                all_modules_meta_map_by_path[mod_data.module_root] = mod_data
                            end
                        else
                            log.warn("Module '%s' (comp %s) missing module_root.", mod_name, comp_name)
                            modules_missing_root = modules_missing_root + 1
                        end
                    end
                end
            end
        end
        log.debug("resolve_and_save_all: Aggregated %d unique modules by path.", vim.tbl_count(all_modules_meta_map_by_path))

        -- ★ Engine チェックログ (パスキーマップ用)
        local engine_meta_found = false
        for path, meta in pairs(all_modules_meta_map_by_path) do
            if meta.name == "Engine" and meta.module_root:find("Runtime/Engine$") then
                log.debug("resolve_and_save_all: FINAL CHECK - 'Engine' module FOUND in all_modules_meta_map_by_path at path: %s", path)
                engine_meta_found = true
                break
            end
        end
        if not engine_meta_found then
            log.error("resolve_and_save_all: FINAL CHECK - CRITICAL - 'Engine' module MISSING from all_modules_meta_map_by_path!")
        end
        
        local modules_to_scan_meta = {} -- キーは module_root パス
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
        -- ▲▲▲ モジュールキャッシュ更新対象決定 (キーをパスに変更) ▲▲▲

        local modules_to_scan_count = vim.tbl_count(modules_to_scan_meta)
        log.debug("resolve_and_save_all: Determined %d modules to scan.", modules_to_scan_count)
        
        -- ▼▼▼ モジュールキャッシュスキャン実行 (★ all_components_map を渡す) ▼▼▼
        if modules_to_scan_count > 0 or (refresh_opts.bang or refresh_opts.force) then
          log.info("Starting file scan for %d module(s) (and component roots)...", modules_to_scan_count)
          refresh_modules_core.create_module_caches_for(
            modules_to_scan_meta,
            all_modules_meta_map_by_path,
            result_data.all_data, -- ★★★ 全コンポーネントマップを渡す
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

      parse_next() -- 最初の呼び出し
    end, -- .uplugin 検索 on_exit 終わり
  }) -- .uplugin 検索 jobstart 終わり
end -- M.update_project_structure 終わり

return M
