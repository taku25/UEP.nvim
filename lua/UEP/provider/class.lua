-- lua/UEP/provider/class.lua (マージ処理修正版)

local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local files_cache_manager = require("UEP.cache.files")
local unl_finder = require("UNL.finder")
local uep_log = require("UEP.logger").get()

local M = {}

function M.request(opts)
  opts = opts or {}
  uep_log.debug("--- UEP Provider 'get_project_classes' CALLED (Manual Merge Mode) ---")
  -- (これより上はデバッグログ版と同じなので省略)
  local project_root = opts.project_root or unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then return nil end
  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache and p_cache.modules then
      all_components_map[comp_name] = p_cache
      for mod_name, mod_data in pairs(p_cache.modules) do
        all_modules_map[mod_name] = mod_data
        module_to_component_name[mod_name] = comp_name
      end
    end
  end
  local target_module_names = {}
  for name, meta in pairs(all_modules_map) do
    if meta.category == "Game" then
      target_module_names[name] = true
      for _, dep_name in ipairs(meta.deep_dependencies or {}) do
        target_module_names[dep_name] = true
      end
    end
  end
  local required_components_map = {}
  for mod_name, _ in pairs(target_module_names) do
    local comp_name = module_to_component_name[mod_name]
    if comp_name and not required_components_map[comp_name] then
      required_components_map[comp_name] = all_components_map[comp_name]
    end
  end

  local merged_header_details = {}
  for _, component_meta in pairs(required_components_map) do
    local files_cache = files_cache_manager.load_component_cache(component_meta)
    if files_cache and files_cache.header_details then
      uep_log.debug("Merging %d header_details from component '%s'", vim.tbl_count(files_cache.header_details), component_meta.display_name)
      
      -- ▼▼▼ 修正箇所: vim.tbl_deep_extend を手動ループに置き換え ▼▼▼
      for file_path, details in pairs(files_cache.header_details) do
        merged_header_details[file_path] = details
      end
      -- ▲▲▲ ここまで ▲▲▲
    end
  end

  local final_count = vim.tbl_count(merged_header_details)
  uep_log.info("Provider: finished. Returning %d relevant header details from %d target modules.", final_count, vim.tbl_count(target_module_names))
  
  return merged_header_details
end

return M
