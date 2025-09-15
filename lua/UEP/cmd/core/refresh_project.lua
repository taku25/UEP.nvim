-- lua/UEP/cmd/core/refresh_project.lua (第三世代・二段階分析・最終完成版)

local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local fs = require("vim.fs")
local unl_analyzer = require("UNL.analyzer.build_cs")
local uep_graph = require("UEP.graph")
local uep_log = require("UEP.logger")
local project_cache = require("UEP.cache.project")

local M = {}

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------
local function get_name_from_root(root_path)
  if not root_path then return nil end
  return unl_path.normalize(root_path):gsub("[\\/:]", "_")
end

local function read_json_file(path)
  if not (path and vim.fn.filereadable(path) == 1) then return nil end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.json.decode, content, {-1, nil, false})
  if ok then return data else return nil end
end

---
-- PASS 1 HELPER: 単一コンポーネントのBuild.csをパースし、「生」のモジュール情報を返す
local function parse_single_component(component, on_done)
  local search_paths
  if component.type == "Engine" then search_paths = { fs.joinpath(component.root_path, "Engine", "Source") }
  elseif component.type == "Game" then search_paths = { fs.joinpath(component.root_path, "Source") }
  else search_paths = { component.root_path } end

  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "Build.cs", unpack(search_paths) }
  local build_cs_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(build_cs_files, line) end end end end,
    on_exit = function(_, code)
      local modules_meta = {}
      if code == 0 and #build_cs_files > 0 then
        for _, raw_path in ipairs(build_cs_files) do
          local build_cs_path = unl_path.normalize(raw_path)
          local module_name = vim.fn.fnamemodify(build_cs_path, ":h:t")
          local module_root = vim.fn.fnamemodify(build_cs_path, ":h")
          local location = build_cs_path:find("/Plugins/", 1, true) and "in_plugins" or "in_source"
          local dependencies = unl_analyzer.parse(build_cs_path)
          modules_meta[module_name] = { name = module_name, path = build_cs_path, module_root = module_root, category = component.type, location = location, dependencies = dependencies }
        end
      end
      on_done(true, modules_meta)
    end,
  })
end

-------------------------------------------------
-- 新しいメインAPI
-------------------------------------------------
function M.update_project_structure(scope, force_regenerate, uproject_path, progress, on_done)
  local log = uep_log.get()
  local game_root = vim.fn.fnamemodify(uproject_path, ":h")
  local engine_root = unl_finder.engine.find_engine_root(uproject_path, {})
  if not engine_root then return on_done(false) end

  local game_name = get_name_from_root(game_root)
  local engine_name = get_name_from_root(engine_root)

  local plugin_search_paths = { fs.joinpath(game_root, "Plugins"), fs.joinpath(engine_root, "Engine", "Plugins") }
  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "--path-separator", "/", "--glob", "*.uplugin", unpack(plugin_search_paths) }
  local all_uplugin_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_uplugin_files, line) end end end end,
    on_exit = function()
      local all_components = {}
      table.insert(all_components, { name = game_name, display_name = vim.fn.fnamemodify(game_root, ":t"), type = "Game", root_path = game_root, owner_name = game_name })
      table.insert(all_components, { name = engine_name, display_name = "Engine", type = "Engine", root_path = engine_root, owner_name = engine_name })
      for _, uplugin_path in ipairs(all_uplugin_files) do
        local plugin_root = vim.fn.fnamemodify(uplugin_path, ":h")
        local owner_name = uplugin_path:find(engine_root, 1, true) and engine_name or game_name
        table.insert(all_components, { name = get_name_from_root(plugin_root), display_name = vim.fn.fnamemodify(uplugin_path, ":t:r"), type = "Plugin", root_path = plugin_root, owner_name = owner_name })
      end
      
      local components_to_process = (scope == "Game" and vim.tbl_filter(function(c) return c.owner_name == game_name end, all_components))
                             or (scope == "Engine" and vim.tbl_filter(function(c) return c.owner_name == engine_name end, all_components))
                             or all_components
      
      -- ▼▼▼ 二段階分析の開始 ▼▼▼
      
      -- PASS 1: 全コンポーネントの「生」のモジュール情報を収集
      progress:stage_define("parse_components", #all_components)
      progress:stage_update("parse_components", 0, "PASS 1: Parsing all Build.cs files...")
      
      local raw_modules_by_component = {}
      local current_index = 1
      local resolve_and_save_all
      
      local function parse_next()
        if current_index > #all_components then
          resolve_and_save_all()
          return
        end
        local component = all_components[current_index]
        parse_single_component(component, function(ok, modules_meta)
          if ok then
            raw_modules_by_component[component.name] = modules_meta
            progress:stage_update("parse_components", current_index, ("Parsed: %s"):format(component.display_name))
            current_index = current_index + 1
            parse_next()
          else
            on_done(false)
          end
        end)
      end

      -- PASS 2: 全モジュール情報を元に、依存関係を解決して保存
      resolve_and_save_all = function()
        progress:stage_update("parse_components", #all_components, "PASS 1 Complete. Aggregating modules...")
        
        -- ▼▼▼ 最重要修正点：より堅牢な方法で全モジュール情報を集約 ▼▼▼
        local all_modules_meta = {}
        for _, component_modules in pairs(raw_modules_by_component) do
          for module_name, module_data in pairs(component_modules) do
            all_modules_meta[module_name] = module_data
          end
        end
        -- ▲▲▲ 修正はここまで ▲▲▲

        -- STEP 2: 【計算フェーズ】全モジュールの依存関係を「一度に」すべて解決する
        progress:stage_define("resolve_deps", 1)
        progress:stage_update("resolve_deps", 0, "PASS 2: Resolving all dependencies...")
        local full_dependency_map, err = uep_graph.resolve_all_dependencies(all_modules_meta)
        if err then
            log.error("Failed to resolve dependencies: %s", tostring(err))
            return on_done(false)
        end
        progress:stage_update("resolve_deps", 1, "Dependency resolution complete.")

        -- STEP 3: 【保存フェーズ】コンポーネントごとに結果を振り分けて保存する
        progress:stage_define("save_components", #components_to_process)
        progress:stage_update("save_components", 0, "Saving component caches...")
        
        local result_data = { all_data = {}, changed_components = {}, full_component_list = all_components }
        
        for i, component in ipairs(components_to_process) do
          local component_raw_modules = raw_modules_by_component[component.name] or {}
          
          local modules_for_this_component = {}
          for module_name, _ in pairs(component_raw_modules) do
            if full_dependency_map[module_name] then
              modules_for_this_component[module_name] = full_dependency_map[module_name]
            end
          end
          
          local content_to_hash = vim.json.encode(modules_for_this_component)
          local new_generation = vim.fn.sha256(content_to_hash)
          
          local new_data = {
            name = component.name, display_name = component.display_name, type = component.type,
            root_path = component.root_path, owner_name = component.owner_name,
            generation = new_generation, modules = modules_for_this_component,
          }

          local cache_filename = component.name .. ".project.json"
          local old_data = project_cache.load(cache_filename)
          local has_changed = not old_data or old_data.generation ~= new_generation

          if force_regenerate or has_changed then
            log.info("Updating project cache for component: %s", component.display_name)
            project_cache.save(cache_filename, new_data)
            table.insert(result_data.changed_components, new_data)
          end
          result_data.all_data[component.name] = new_data
          progress:stage_update("save_components", i)
        end
        
        on_done(true, result_data)
      end
      
      parse_next() -- PASS 1 を開始
    end,
  })
end

return M
