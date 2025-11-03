-- lua/UEP/provider/class.lua (モジュールキャッシュ対応版)

local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
-- local files_cache_manager = require("UEP.cache.files") -- [!] 削除
local module_cache = require("UEP.cache.module") -- [!] 追加
local unl_finder = require("UNL.finder")
local uep_log = require("UEP.logger").get()

local M = {}

function M.request(opts)
  opts = opts or {}
  uep_log.debug("--- UEP Provider 'get_project_classes' CALLED (Module Cache Mode) ---")
  
  -- STEP 1: プロジェクトとコンポーネントマップのロード (変更なし)
  local project_root = opts.project_root or unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end
  local project_display_name = vim.fn.fnamemodify(project_root, ":t")
  local project_registry_info = projects_cache.get_project_info(project_display_name)
  if not project_registry_info or not project_registry_info.components then return nil end
  
  local all_modules_map, module_to_component_name, all_components_map = {}, {}, {}
  for _, comp_name in ipairs(project_registry_info.components) do
    local p_cache = project_cache.load(comp_name .. ".project.json")
    -- [!] p_cache.modules ではなく、新しいモジュールリストのキーをチェック
    if p_cache then
      all_components_map[comp_name] = p_cache
      -- 構造キャッシュからモジュールマップを再構築
      for _, type_key in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do
        if p_cache[type_key] then
          for mod_name, mod_data in pairs(p_cache[type_key]) do
            all_modules_map[mod_name] = mod_data
            module_to_component_name[mod_name] = comp_name
          end
        end
      end
    end
  end

  -- STEP 2: 対象モジュールのフィルタリング (変更なし)
  -- (ここでは例として 'Game' スコープ + deep_deps だった場合を想定)
  local target_module_names = {}
  for name, meta in pairs(all_modules_map) do
    if meta.category == "Game" then
      target_module_names[name] = true
      for _, dep_name in ipairs(meta.deep_dependencies or {}) do
        target_module_names[dep_name] = true
      end
    end
  end
  
  -- STEP 3: 対象コンポーネントの特定 (変更なし)
  local required_components_map = {}
  for mod_name, _ in pairs(target_module_names) do
    local comp_name = module_to_component_name[mod_name]
    if comp_name and not required_components_map[comp_name] then
      required_components_map[comp_name] = all_components_map[comp_name]
    end
  end

  -- ▼▼▼ 修正箇所 ▼▼▼
  -- STEP 4: モジュールキャッシュから header_details をマージ
  local merged_header_details = {}
  
  -- 対象コンポーネントをループ
  for comp_name, component_meta in pairs(required_components_map) do
    uep_log.trace("Scanning component '%s' for target modules...", component_meta.display_name)
    
    -- コンポーネント内のモジュールタイプをループ
    for _, type_key in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do
      if component_meta[type_key] then
        
        -- モジュールをループ
        for mod_name, mod_meta in pairs(component_meta[type_key]) do
          
          -- [!] このモジュールがSTEP 2でフィルタリングされた対象モジュールかチェック
          if target_module_names[mod_name] then
            -- [!] module_cache をロード
            local mod_cache = module_cache.load(mod_meta)
            if mod_cache and mod_cache.header_details then
              uep_log.trace("...merging %d headers from module '%s'", vim.tbl_count(mod_cache.header_details), mod_name)
              -- header_details をマージ
              for file_path, details in pairs(mod_cache.header_details) do
                merged_header_details[file_path] = details
              end
            end
          end
        end
      end
    end
  end
  -- ▲▲▲ 修正完了 ▲▲▲

  local final_count = vim.tbl_count(merged_header_details)
  uep_log.info("Provider: finished. Returning %d relevant header details from %d target modules.", final_count, vim.tbl_count(target_module_names))
  
  return merged_header_details
end

return M
