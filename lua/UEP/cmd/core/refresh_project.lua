-- lua/UEP/cmd/core/refresh_project.lua (第三世代・究極の司令部・最終完成版)

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

local function analyze_single_component(component, all_components_data, on_component_done)
  local search_paths
  if component.type == "Engine" then
    search_paths = { fs.joinpath(component.root_path, "Engine", "Source") }
  elseif component.type == "Game" then
    search_paths = { fs.joinpath(component.root_path, "Source") }
  else -- Plugin
    search_paths = { component.root_path }
  end
  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "Build.cs", unpack(search_paths) }

  print(vim.inspect(fd_cmd))
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
          local location = build_cs_path:find("/Plugins/", 1, true) and "in_plugins" or (build_cs_path:find("/Source/", 1, true) and "in_source" or "unknown")
          local dependencies = unl_analyzer.parse(build_cs_path)
          modules_meta[module_name] = { name = module_name, path = build_cs_path, module_root = module_root, category = component.type, location = location, dependencies = dependencies }
        end
      end
      local all_other_modules = {}
      for _, comp_data in pairs(all_components_data) do
        if comp_data and comp_data.modules then vim.tbl_deep_extend("force", all_other_modules, comp_data.modules) end
      end
      local modules_with_resolved_deps, _ = uep_graph.resolve_all_dependencies(modules_meta, all_other_modules)
      local content_to_hash = vim.json.encode(modules_with_resolved_deps or {})
      local data_hash = vim.fn.sha256(content_to_hash)
      local component_data = {
        name = component.name, display_name = component.display_name, type = component.type,
        root_path = component.root_path, owner_name = component.owner_name,
        generation = data_hash, modules = modules_with_resolved_deps or {},
      }
      project_cache.save(component.name .. ".project.json", component_data)
      on_component_done(true, component_data)
    end,
  })
end

-------------------------------------------------
-- 新しいAPI
-------------------------------------------------
function M.get_full_component_list(uproject_path, progress, on_list_ready)
  local log = uep_log.get()
  progress:stage_update("find_plugins", 0, "Finding all plugins...")
  local game_root = vim.fn.fnamemodify(uproject_path, ":h")
  local engine_root = unl_finder.engine.find_engine_root(uproject_path, {})
  if not engine_root then
    if on_list_ready then on_list_ready(false) end
    return
  end
  local search_paths = { fs.joinpath(game_root, "Plugins"), fs.joinpath(engine_root, "Engine", "Plugins") }
  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "--path-separator", "/", "--glob", "*.uplugin", unpack(search_paths) }

  print(vim.inspect(fd_cmd))
  local all_uplugin_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_uplugin_files, line) end end end end,
    on_exit = function()
      local components = {}
      local unique_components = {}
      local game_name = get_name_from_root(game_root)
      local engine_name = get_name_from_root(engine_root)
      table.insert(components, { name = game_name, display_name = vim.fn.fnamemodify(game_root, ":t"), type = "Game", root_path = game_root, owner_name = game_name, game_name = game_name, engine_name = engine_name })
      unique_components[game_root] = true
      table.insert(components, { name = engine_name, display_name = "Engine", type = "Engine", root_path = engine_root, owner_name = engine_name, game_name = game_name, engine_name = engine_name })
      unique_components[engine_root] = true
      for _, uplugin_path in ipairs(all_uplugin_files) do
        local plugin_root = vim.fn.fnamemodify(uplugin_path, ":h")
        local uplugin_data = read_json_file(uplugin_path)
        if uplugin_data and not unique_components[plugin_root] then
          unique_components[plugin_root] = true
          local owner_name = uplugin_path:find(engine_root, 1, true) and engine_name or game_name
          table.insert(components, {
            name = get_name_from_root(plugin_root), display_name = vim.fn.fnamemodify(uplugin_path, ":t:r"), type = "Plugin",
            root_path = plugin_root, owner_name = owner_name, game_name = game_name, engine_name = engine_name,
          })
        end
      end
      progress:stage_update("find_plugins", 1, "Found " .. #components .. " total components.")
      if on_list_ready then on_list_ready(true, components) end
    end,
  })
end

function M.analyze_selected_components(components_to_analyze, existing_data, progress, on_analysis_done)
  progress:stage_define("analyze_components", #components_to_analyze)
  local final_component_data = {}
  local current_index = 1
  local function process_next_component()
    if current_index > #components_to_analyze then
      progress:stage_update("analyze_components", #components_to_analyze, "Analysis complete.")
      on_analysis_done(true, final_component_data)
      return
    end
    local component = components_to_analyze[current_index]
    local msg = ("[%d/%d] Analyzing: %s"):format(current_index, #components_to_analyze, component.display_name)
    progress:stage_update("analyze_components", current_index - 1, msg)
    analyze_single_component(component, existing_data, function(ok, result)
      if ok then
        final_component_data[component.name] = result
        current_index = current_index + 1
        process_next_component()
      else
        uep_log.get().error("Failed to analyze component: %s. Aborting.", component.display_name)
        on_analysis_done(false)
      end
    end)
  end
  process_next_component()
end

return M
