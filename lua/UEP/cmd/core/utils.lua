
local unl_finder = require("UNL.finder")
local project_cache = require("UEP.cache.project")
local projects_cache = require("UEP.cache.projects")

local M = {}
-- ▲▲▲ ここまで ▲▲▲
-- refresh_files.luaから持ってきたヘルパー関数
M.categorize_path = function(path)
  if path:match("%.uproject$") then return "uproject" end
  if path:find("/Shaders/", 1, true) or path:match("/Shaders$") then return "shader" end
  if path:find("/Config/", 1, true) or path:match("/Config$") then return "config" end
  if path:find("/Source/", 1, true) or path:match("/Source$") then return "source" end
  if path:find("/Programs/", 1, true) or path:match("/Programs$") then return "programs" end
  if path:find("/Content/", 1, true) or path:match("/Content$") then return "content" end
  if path:find("/Plugins/", 1, true) then return "source" end
  return "other"
end

M. get_project_maps =  function(start_path, on_complete)
  local project_root = unl_finder.project.find_project_root(start_path)
  if not project_root then
    return on_complete(false, "Could not find project root.")
  end
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then
    return on_complete(false, "Project not found in registry. Please run :UEP refresh.")
  end

  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache then
      all_components_map[comp_name] = p_cache
      for mod_name, mod_data in pairs(p_cache.modules or {}) do
        all_modules_map[mod_name] = mod_data
        module_to_component_name[mod_name] = comp_name
      end
    end
  end
  
  on_complete(true, {
    project_root = project_root,
    all_modules_map = all_modules_map,
    module_to_component_name = module_to_component_name,
    all_components_map = all_components_map,
    project_registry_info = project_registry_info,
  })
end

---
-- 絶対パスを、指定されたベースパスからの相対パスに変換する
-- @param full_path string 対象の絶対パス
-- @param base_path string 基準となるディレクトリのパス
-- @return string 相対パス。変換できない場合は元のパスを返す。
function M.create_relative_path(file_path, base_path)
  if not file_path or not base_path then
    return file_path
  end

  -- 1. パス区切り文字をスラッシュに統一
  local norm_file = file_path:gsub("\\", "/")
  local norm_base = base_path:gsub("\\", "/")

  -- 2. パスをコンポーネントに分割
  local file_parts = vim.split(norm_file, "/", { plain = true })
  local base_parts = vim.split(norm_base, "/", { plain = true })

  local common_len = 0
  -- 3. 共通のプレフィックスがどこまで続くかを探す (大文字小文字を区別しない)
  for i = 1, math.min(#file_parts, #base_parts) do
    if file_parts[i]:lower() == base_parts[i]:lower() then
      common_len = i
    else
      break
    end
  end

  -- 4. 共通部分が見つかった場合、残りの部分を結合して相対パスを作成
  if common_len > 0 and common_len < #file_parts then
    local relative_parts = {}
    for i = common_len + 1, #file_parts do
      table.insert(relative_parts, file_parts[i])
    end
    return table.concat(relative_parts, "/")
  end

  -- 5. 共通部分がない、または完全に一致する場合は、元のパスを返す
  return file_path
end

return M
