-- lua/UEP/cmd/core/refresh_project.lua (アプローチ2 修正版)

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

---
-- .uproject / .uplugin をJSONとして解析し、モジュール名->タイプ のマップを作成する
-- @param path string .uproject または .uplugin のパス
-- @return table|nil { ModuleName = "Runtime", ... } または nil
local function parse_project_or_plugin_file(path)
  local log = uep_log.get()
  local json_string = table.concat(vim.fn.readfile(path), "")
  if vim.v.shell_error ~= 0 or json_string == "" then
    log.warn("Could not read project/plugin file: %s", path)
    return nil
  end

  local ok, data = pcall(vim.json.decode, json_string)
  if not ok or not data or not data.Modules or type(data.Modules) ~= "table" then
    -- モジュール定義がないプラグインは正常（例: コンテンツのみのプラグイン）
    -- log.debug("No modules defined in: %s", path)
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

---
-- Build.cs を解析し、モジュールメタデータを作成する
-- ★ module_type_map を引数に追加
-- ▼▼▼ 修正箇所 ▼▼▼
local function parse_single_component(component, module_type_map, on_done)
  local log = uep_log.get()
  local search_paths = {}

if component.type == "Engine" then
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Source", "Runtime"))
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Source", "Developer"))
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Source", "Editor"))
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Source", "Programs")) -- ★ 追加
    table.insert(search_paths, fs.joinpath(component.root_path, "Engine", "Programs"))         -- ★ 追加
  elseif component.type == "Game" then
    table.insert(search_paths, fs.joinpath(component.root_path, "Source"))
    -- ▼▼▼ 修正箇所: Game の Programs パスも考慮 ▼▼▼
    table.insert(search_paths, fs.joinpath(component.root_path, "Programs")) -- ★ 追加 (あれば)
    -- ▲▲▲ 修正ここまで ▲▲▲
  else -- Plugin の場合
    table.insert(search_paths, component.root_path)
  end

  if #search_paths == 0 then
    log.warn("No valid search paths found for component '%s'. Skipping Build.cs search.", component.display_name)
    on_done(true, { meta = {}, mtimes = {} })
    return
  end

  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "Build.cs" }
  for _, spath in ipairs(search_paths) do
    table.insert(fd_cmd, "--search-path")
    table.insert(fd_cmd, spath)
  end

  local build_cs_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(build_cs_files, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      local modules_meta = {}
      local source_mtimes = {}
      if code == 0 and #build_cs_files > 0 then
        for _, raw_path in ipairs(build_cs_files) do
          local build_cs_path = unl_path.normalize(raw_path)
          source_mtimes[build_cs_path] = vim.fn.getftime(build_cs_path)
          local module_name = vim.fn.fnamemodify(build_cs_path, ":t:r:r")
          local module_root = vim.fn.fnamemodify(build_cs_path, ":h")
          local location = build_cs_path:find("/Plugins/", 1, true) and "in_plugins" or "in_source"
          local dependencies = unl_analyzer.parse(build_cs_path)

-- ▼▼▼ タイプ判定ロジック修正 ▼▼▼
          local mod_type = module_type_map[module_name]
          local type_source = "None"

          if mod_type then
              type_source = "Plugin/Project File"
          else
            local lower_path = build_cs_path:lower()
            -- ★ Programs パスを最優先でチェック
            if lower_path:find("/programs/", 1, true) then
                 mod_type = "Program"; type_source = "Path (Programs)"
            elseif lower_path:find("/engine/source/runtime/", 1, true) then
              mod_type = "Runtime"; type_source = "Path (Runtime)"
            elseif lower_path:find("/engine/source/developer/", 1, true) then
              mod_type = "Developer"; type_source = "Path (Developer)"
            elseif lower_path:find("/engine/source/editor/", 1, true) then
              mod_type = "Editor"; type_source = "Path (Editor)"
            elseif component.type == "Game" and location == "in_source" then
              mod_type = "Runtime"; type_source = "Path (Game Source)"
            end
          end

          if not mod_type then
            mod_type = "Runtime"; type_source = "Default (Runtime)"
          end
          -- ▲▲▲ タイプ判定修正ここまで ▲▲▲
          
          -- ★ デバッグログ出力
          -- if module_name == "GraphEditor" or module_name == "UnrealEd" then -- 特定モジュールのみログ出力
              -- log.trace("Module Type Determination: Name=%s, Type=%s, Source=%s (Path: %s)",
              --          module_name, mod_type, type_source, build_cs_path)
          -- end
          -- ▲▲▲ タイプ判定 + デバッグログここまで ▲▲▲

          modules_meta[module_name] = {
            name = module_name, path = build_cs_path, module_root = module_root,
            category = component.type, location = location, dependencies = dependencies,
            owner_name = component.owner_name,
            type = mod_type,
          }
        end
      end
      on_done(true, { meta = modules_meta, mtimes = source_mtimes })
    end,
  })
end
-- ▲▲▲ 修正ここまで ▲▲▲

-------------------------------------------------
-- 新しいメインAPI
-------------------------------------------------
function M.update_project_structure(refresh_opts, uproject_path, progress, on_done)
  local log = uep_log.get()
  local game_root = vim.fn.fnamemodify(uproject_path, ":h")
  local engine_root = unl_finder.engine.find_engine_root(uproject_path, {
    engine_override_path = uep_config.get().engine_path,
  })
  if not engine_root then return on_done(false) end

  local game_name = get_name_from_root(game_root)
  local engine_name = get_name_from_root(engine_root)
  local uproject_mtime = vim.fn.getftime(uproject_path)

  local plugin_search_paths = {
    fs.joinpath(game_root, "Plugins"),
    fs.joinpath(engine_root, "Engine", "Plugins"),
    fs.joinpath(engine_root, "Engine", "Platforms"),
    fs.joinpath(engine_root, "Engine", "Source", "Developer")
  }
  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "--path-separator", "/", "--glob", "*.uplugin", unpack(plugin_search_paths) }
  local all_uplugin_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(all_uplugin_files, line)
          end
        end
      end
    end,
    on_exit = function()
      -- ▼▼▼ 修正箇所: .uproject/.uplugin を先に解析する ▼▼▼
      log.info("Found %d .uplugin files. Parsing project and plugin definitions...", #all_uplugin_files)
      local module_type_map = {}

      -- 1. メインの .uproject を解析
      local uproject_types = parse_project_or_plugin_file(uproject_path)
      if uproject_types then
        for name, type in pairs(uproject_types) do module_type_map[name] = type end
      end
      
      -- 2. 見つかった全 .uplugin を解析
      for _, uplugin_path in ipairs(all_uplugin_files) do
        local uplugin_types = parse_project_or_plugin_file(uplugin_path)
        if uplugin_types then
          for name, type in pairs(uplugin_types) do module_type_map[name] = type end
        end
      end
      log.info("Finished parsing. Found type definitions for %d modules.", vim.tbl_count(module_type_map))
      -- ▲▲▲ 修正ここまで ▲▲▲

      local all_components = {}
      table.insert(all_components, { name = game_name, display_name = vim.fn.fnamemodify(game_root, ":t"), type = "Game", root_path = game_root, owner_name = game_name })
      table.insert(all_components, { name = engine_name, display_name = "Engine", type = "Engine", root_path = engine_root, owner_name = engine_name })
      for _, uplugin_path in ipairs(all_uplugin_files) do
        local plugin_root = vim.fn.fnamemodify(uplugin_path, ":h")
        local owner_name = uplugin_path:find(engine_root, 1, true) and engine_name or game_name
        table.insert(all_components, { name = get_name_from_root(plugin_root), display_name = vim.fn.fnamemodify(uplugin_path, ":t:r"), type = "Plugin", root_path = plugin_root, owner_name = owner_name })
      end
      
      local components_to_process = (refresh_opts.scope == "Game" and vim.tbl_filter(function(c) return c.owner_name == game_name end, all_components))
                             or (refresh_opts.scope == "Engine" and vim.tbl_filter(function(c) return c.owner_name == engine_name end, all_components))
                             or all_components
      
      progress:stage_define("parse_components", #all_components)
      progress:stage_update("parse_components", 0, "PASS 1: Parsing all Build.cs files...")
      
      local raw_modules_by_component = {}
      local source_mtimes_by_component = {}
      local current_index = 1
      local resolve_and_save_all
      
      local function parse_next()
        if current_index > #all_components then
          resolve_and_save_all()
          return
        end
        local component = all_components[current_index]
        -- ▼▼▼ 修正箇所: module_type_map を渡す ▼▼▼
        parse_single_component(component, module_type_map, function(ok, result)
        -- ▲▲▲ 修正ここまで ▲▲▲
          if ok then
            raw_modules_by_component[component.name] = result.meta
            source_mtimes_by_component[component.name] = result.mtimes
            progress:stage_update("parse_components", current_index, ("Parsed: %s [%d/%d]"):format(component.display_name, current_index, #all_components))
            current_index = current_index + 1
            vim.schedule(parse_next)
          else
            on_done(false)
          end
        end)
      end

      resolve_and_save_all = function()
        progress:stage_update("parse_components", #all_components, "PASS 1 Complete. Aggregating modules...")
        
        local all_modules_meta = {}
        for _, component_modules in pairs(raw_modules_by_component) do
          for module_name, module_data in pairs(component_modules) do
            all_modules_meta[module_name] = module_data
          end
        end

        progress:stage_define("resolve_deps", 1)
        progress:stage_update("resolve_deps", 0, "PASS 2: Resolving all dependencies...")
        local full_dependency_map, err = uep_graph.resolve_all_dependencies(all_modules_meta)
        if err then
            log.error("Failed to resolve dependencies: %s", tostring(err))
            return on_done(false)
        end
        progress:stage_update("resolve_deps", 1, "Dependency resolution complete.")

        progress:stage_define("save_components", #components_to_process)
        progress:stage_update("save_components", 0, "Saving component caches...")
        
        local result_data = { all_data = {}, changed_components = {}, full_component_list = all_components }
        
        for i, component in ipairs(components_to_process) do
          local component_raw_modules = raw_modules_by_component[component.name] or {}
          
          local runtime_modules, developer_modules, editor_modules, programs_modules = {}, {}, {}, {} -- ★ programs_modules を追加

          for module_name, _ in pairs(component_raw_modules) do
            if full_dependency_map[module_name] then
              local mod_meta = full_dependency_map[module_name]
              local mod_type = mod_meta.type

              if mod_type then
                local clean_type_lower = mod_type:match("^%s*(.-)%s*$"):lower()

                -- ★ Program タイプを最優先でチェック
                if clean_type_lower == "program" then
                    programs_modules[module_name] = mod_meta
                elseif clean_type_lower == "developer" then
                    developer_modules[module_name] = mod_meta
                elseif clean_type_lower:find("editor", 1, true) or clean_type_lower == "uncookedonly" then
                    editor_modules[module_name] = mod_meta
                else -- それ以外は Runtime
                    runtime_modules[module_name] = mod_meta
                end
              else
                runtime_modules[module_name] = mod_meta
              end
            end
          end
          
          -- ハッシュ計算の対象を新しい3つのマップに変更
          local content_to_hash = vim.json.encode({
            r = runtime_modules, d = developer_modules, e = editor_modules
          })
          local new_generation = vim.fn.sha256(content_to_hash)
          -- ▲▲▲ 修正ここまで ▲▲▲
          
          local source_mtimes = source_mtimes_by_component[component.name] or {}
          source_mtimes[uproject_path] = uproject_mtime

          -- ▼▼▼ 修正箇所: 保存するデータ構造を アプローチ2 に変更 ▼▼▼
          local new_data = {
            name = component.name, display_name = component.display_name, type = component.type,
            root_path = component.root_path, owner_name = component.owner_name,
            generation = new_generation,
            source_mtimes = source_mtimes,
            -- "modules" フィールドは廃止
            runtime_modules = runtime_modules,
            developer_modules = developer_modules,
            editor_modules = editor_modules,
            programs_modules = programs_modules, -- ★ programs_modules を追加
          }
          -- ▲▲▲ 修正ここまで ▲▲▲

          local cache_filename = component.name .. ".project.json"
          local old_data = project_cache.load(cache_filename)
          
          local has_changed = false
          if refresh_opts.force then
            has_changed = true
            log.info("Forced update for component: %s", component.display_name)
          elseif not old_data then
            has_changed = true
          elseif refresh_opts.bang then
            has_changed = (old_data.generation ~= new_generation)
          else
            local cache_is_stale = false
            if old_data.source_mtimes then
              for path, old_mtime in pairs(old_data.source_mtimes) do
                if (vim.fn.filereadable(path) == 0) or (vim.fn.getftime(path) > old_mtime) then
                  cache_is_stale = true
                  break
                end
              end
            else
              cache_is_stale = true
            end
            if cache_is_stale then
              has_changed = (old_data.generation ~= new_generation)
            end
          end

          if has_changed then
            log.info("Updating project cache for component: %s", component.display_name)
            project_cache.save(cache_filename, new_data)
            table.insert(result_data.changed_components, new_data)
          end
          result_data.all_data[component.name] = has_changed and new_data or old_data
          progress:stage_update("save_components", i)
        end
        
        
        -- ★★★ ここから モジュールキャッシュへの移行ロジック ★★★
        
        -- STEP 2.5: 全コンポーネントの全モジュールを集約したマップを作成
        local all_modules_meta_map = {}
        for _, component_data in pairs(result_data.all_data) do
          -- ▼▼▼ 修正箇所: 3つのマップから集約する ▼▼▼
          vim.list_extend(all_modules_meta_map, component_data.runtime_modules or {})
          vim.list_extend(all_modules_meta_map, component_data.developer_modules or {})
          vim.list_extend(all_modules_meta_map, component_data.editor_modules or {})
          vim.list_extend(all_modules_meta_map, component_data.programs_modules or {}) -- ★ 追加
          -- ▲▲▲ 修正ここまで ▲▲▲
        end

        -- STEP 3: ファイルスキャン対象の「モジュール」を決定する
        local modules_to_scan_meta = {}

        if refresh_opts.bang or refresh_opts.force then
          log.info("Bang(!) or --force specified. All modules in scope will be scanned for files.")
          if refresh_opts.scope == "Full" then
            modules_to_scan_meta = all_modules_meta_map
          else
            local owner_name_to_match = (refresh_opts.scope == "Engine" and engine_name) or game_name
            for mod_name, mod_meta in pairs(all_modules_meta_map) do
              if mod_meta.owner_name == owner_name_to_match then
                 modules_to_scan_meta[mod_name] = mod_meta
              end
            end
          end
        else
          local function add_module_to_scan_list(mod_meta)
              if mod_meta and mod_meta.name and not modules_to_scan_meta[mod_meta.name] then
                  modules_to_scan_meta[mod_meta.name] = mod_meta
              end
          end
          
          -- B-1: 構造が変更されたコンポーネントに含まれる「全モジュール」を追加
          for _, c in ipairs(result_data.changed_components) do
            -- ▼▼▼ 修正箇所: 3つのマップから集約する ▼▼▼
            if c.runtime_modules then for _, mod_meta in pairs(c.runtime_modules) do add_module_to_scan_list(mod_meta) end end
            if c.developer_modules then for _, mod_meta in pairs(c.developer_modules) do add_module_to_scan_list(mod_meta) end end
            if c.editor_modules then for _, mod_meta in pairs(c.editor_modules) do add_module_to_scan_list(mod_meta) end end
            if c.programs_modules then for _, mod_meta in pairs(c.programs_modules) do add_module_to_scan_list(mod_meta) end end -- ★ 追加
            -- ▲▲▲ 修正ここまで ▲▲▲
          end

          -- B-2: モジュールキャッシュが存在しないモジュールを追加
          for mod_name, mod_meta in pairs(all_modules_meta_map) do
            if not modules_to_scan_meta[mod_name] then
              if not module_cache.load(mod_meta) then
                log.info("Module cache for '%s' not found. Adding to scan queue.", mod_name)
                add_module_to_scan_list(mod_meta)
              end
            end
          end
        end

        -- STEP 4: 決定した対象リストに基づいてファイルスキャンを実行 (変更なし)
        local modules_to_scan_count = vim.tbl_count(modules_to_scan_meta)
        if modules_to_scan_count > 0 then
          log.info("Starting file scan for %d module(s).", modules_to_scan_count)
          refresh_modules_core.create_module_caches_for(
            modules_to_scan_meta,
            all_modules_meta_map,
            progress,
            game_root,
            engine_root,
            function(files_ok)
              on_done(true and files_ok, result_data) 
            end
          )
        else
          log.info("Project structure is up-to-date and all module caches exist. Nothing to refresh.")
          on_done(true, result_data)
        end
        
      end
      
      parse_next()
    end,
  })
end

return M
