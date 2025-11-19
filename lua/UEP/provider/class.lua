-- lua/UEP/provider/class.lua (最終版: deps_flag 対応)

local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local module_cache = require("UEP.cache.module")
local unl_finder = require("UNL.finder")
local uep_log = require("UEP.logger").get()

local M = {}

function M.request(opts)
  opts = opts or {}
  uep_log.debug("--- UEP Provider 'get_project_classes' CALLED ---")
  
  -- 1. Depsフラグの決定 (デフォルトをどうするかはここで決める)
  -- "smart" な挙動にするなら、デフォルトを --shallow-deps にするのも手です
  local deps_flag = opts.deps_flag or "--deep-deps" 

  -- STEP 1: プロジェクト情報のロード (変更なし)
  local project_root = opts.project_root or unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then return nil end
  
  local all_modules_map = {}
  local all_components_map = {}
  
  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    if p_cache then
      all_components_map[comp_name] = p_cache
      for _, type_key in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do
        if p_cache[type_key] then
          for mod_name, mod_data in pairs(p_cache[type_key]) do
            all_modules_map[mod_name] = mod_data
          end
        end
      end
    end
  end

  -- STEP 2: 対象モジュールのフィルタリング (Depsフラグを考慮)
  local target_module_names = {}
  local requested_scope = (opts.scope and opts.scope:lower()) or "runtime"

  for name, meta in pairs(all_modules_map) do
    local should_add_seed = false
    
    -- 起点となるモジュール（自分のプロジェクトやプラグイン）を決める
    if requested_scope == "game" then
        if meta.category == "Game" then should_add_seed = true end
    elseif requested_scope == "engine" then
        if meta.category == "Engine" then should_add_seed = true end
    elseif requested_scope == "runtime" or requested_scope == "full" then
        if meta.type == "Runtime" then should_add_seed = true end
        if meta.category == "Plugin" then should_add_seed = true end
    end
    
    if opts.scope == nil then -- フォールバック
        if meta.type == "Runtime" or meta.category == "Game" or meta.category == "Plugin" then
            should_add_seed = true
        end
    end

    if should_add_seed then
      target_module_names[name] = true
      
      -- ▼▼▼ ここでフラグに応じて依存関係を追加 ▼▼▼
      local deps_list = {}
      if deps_flag == "--shallow-deps" then
          deps_list = meta.shallow_dependencies or {}
      elseif deps_flag == "--deep-deps" then
          deps_list = meta.deep_dependencies or {}
      elseif deps_flag == "--no-deps" then
          deps_list = {}
      end

      for _, dep_name in ipairs(deps_list) do
        target_module_names[dep_name] = true
      end
      -- ▲▲▲ 修正完了 ▲▲▲
    end
  end
  
  -- STEP 3: キャッシュのマージ (変更なし)
  local merged_header_details = {}
  for comp_name, component_meta in pairs(all_components_map) do
    for _, type_key in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do
      if component_meta[type_key] then
        for mod_name, mod_meta in pairs(component_meta[type_key]) do
          if target_module_names[mod_name] then
            local mod_cache = module_cache.load(mod_meta)
            if mod_cache and mod_cache.header_details then
              for file_path, details in pairs(mod_cache.header_details) do
                merged_header_details[file_path] = details
              end
            end
          end
        end
      end
    end
  end

  local final_count = vim.tbl_count(merged_header_details)
  uep_log.info("Provider: finished (%s). Returning %d headers.", deps_flag, final_count)
  
  return merged_header_details
end

return M
