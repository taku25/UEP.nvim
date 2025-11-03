-- lua/UEP/cmd/core/utils.lua (pairs ループ修正版 - 完全版)

local unl_finder = require("UNL.finder")
local project_cache = require("UEP.cache.project")
local projects_cache = require("UEP.cache.projects")
local unl_path = require("UNL.path")
local uep_log = require("UEP.logger")

local M = {}

-- (categorize_path は変更なし)
M.categorize_path = function(path)
  if path:find("/Programs/", 1, true) or path:match("/Programs$") then return "programs" end
  if path:match("%.uproject$") then return "uproject" end
  if path:match("%.uplugin$") then return "uplugin" end
  if path:find("/Shaders/", 1, true) or path:match("/Shaders$") then return "shader" end
  if path:find("/Config/", 1, true) or path:match("/Config$") then return "config" end
  if path:find("/Source/", 1, true) or path:match("/Source$") then return "source" end
  if path:find("/Content/", 1, true) or path:match("/Content$") then return "content" end
  if path:find("/Plugins/", 1, true) then return "source" end -- Plugin の Source も source 扱い
  return "other"
end

-- ▼▼▼ get_project_maps を修正 ▼▼▼
M.get_project_maps = function(start_path, on_complete)
  local log = uep_log.get()
  log.debug("get_project_maps called...")
  local start_time = os.clock()

  local project_root = unl_finder.project.find_project_root(start_path)
  if not project_root then
    log.error("get_project_maps: Could not find project root.")
    return on_complete(false, "Could not find project root.")
  end

  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then
    log.warn("get_project_maps: Project not found in registry.")
    return on_complete(false, "Project not found in registry. Please run :UEP refresh.")
  end

  local all_modules_map = {}
  local module_to_component_name = {}
  local all_components_map = {}
  local runtime_modules_map = {}
  local developer_modules_map = {}
  local editor_modules_map = {}
  local programs_modules_map = {}
  local game_name, engine_name

  -- ★★★ 修正箇所: ループ変数の使い方を修正 ★★★
  local module_types_info = {
      { key = "runtime_modules", map = runtime_modules_map, type_val = "Runtime" },
      { key = "developer_modules", map = developer_modules_map, type_val = "Developer" },
      { key = "editor_modules", map = editor_modules_map, type_val = "Editor" },
      { key = "programs_modules", map = programs_modules_map, type_val = "Program" }
  }

  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache then
      all_components_map[comp_name] = p_cache
      if p_cache.type == "Game" then game_name = comp_name end
      if p_cache.type == "Engine" then engine_name = comp_name end

      -- 各モジュールタイプからメタデータを集約
      for _, type_info in ipairs(module_types_info) do -- ★ ipairs を使い、変数名を type_info に変更
          local cache_key = type_info.key         -- ★ type_info.key を使う
          local target_map = type_info.map        -- ★ type_info.map を使う
          local default_type = type_info.type_val -- ★ type_info.type_val を使う

          if p_cache[cache_key] then
              for mod_name, mod_data in pairs(p_cache[cache_key]) do
                  -- all_modules_map に type 情報を追加して格納
                  mod_data.type = mod_data.type or default_type -- ★ default_type を使う
                  all_modules_map[mod_name] = mod_data
                  -- タイプ別マップにも格納
                  target_map[mod_name] = mod_data -- ★ target_map (マップそのもの) に代入
                  -- 逆引きマップを作成
                  module_to_component_name[mod_name] = comp_name
              end
          end
      end
    else
        log.warn("get_project_maps: Failed to load project cache for component '%s'", comp_name)
    end
  end
  -- ★★★ 修正ここまで ★★★

  local end_time = os.clock()
  log.debug("get_project_maps finished in %.4f seconds. Found %d modules across %d components.",
            end_time - start_time, vim.tbl_count(all_modules_map), vim.tbl_count(all_components_map))

  -- engine_root の取得を試みる
  local engine_root = nil
  if project_registry_info.engine_association then
      local engine_info = projects_cache.get_engine_info(project_registry_info.engine_association)
      if engine_info then engine_root = engine_info.engine_root end
  end

  on_complete(true, {
    project_root = project_root,
    engine_root = engine_root, -- nil の可能性あり
    all_modules_map = all_modules_map,
    module_to_component_name = module_to_component_name,
    all_components_map = all_components_map,
    runtime_modules_map = runtime_modules_map,
    developer_modules_map = developer_modules_map,
    editor_modules_map = editor_modules_map,
    programs_modules_map = programs_modules_map,
    project_registry_info = project_registry_info,
    game_component_name = game_name,
    engine_component_name = engine_name,
  })
end
-- ▲▲▲ get_project_maps 修正ここまで ▲▲▲


-- (create_relative_path は変更なし)
M.create_relative_path = function(file_path, base_path)
  if not file_path or not base_path then return file_path end
  local norm_file = file_path:gsub("\\", "/")
  local norm_base = base_path:gsub("\\", "/")
  local file_parts = vim.split(norm_file, "/", { plain = true })
  local base_parts = vim.split(norm_base, "/", { plain = true })
  local common_len = 0
  for i = 1, math.min(#file_parts, #base_parts) do
    if file_parts[i]:lower() == base_parts[i]:lower() then common_len = i else break end
  end
  if common_len > 0 and common_len < #file_parts then
    local relative_parts = {}
    for i = common_len + 1, #file_parts do table.insert(relative_parts, file_parts[i]) end
    return table.concat(relative_parts, "/")
  end
  return file_path
end

-- (find_module_for_path は変更なし)
M.find_module_for_path = function(file_path, all_modules_map)
  if not file_path or not all_modules_map then return nil end
  local normalized_path = unl_path.normalize(file_path)
  local best_match = nil; local longest_path = 0
  for _, module_meta in pairs(all_modules_map) do
    if module_meta.module_root then
      local normalized_root = unl_path.normalize(module_meta.module_root)
      if normalized_path:find(normalized_root, 1, true) and #normalized_root > longest_path then
        longest_path = #normalized_root; best_match = module_meta
      end
    end
  end
  return best_match
end

return M
