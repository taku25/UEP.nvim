-- lua/UEP/provider/class.lua (最終版: deps_flag 対応)

local uep_db = require("UEP.db.init")
local unl_finder = require("UNL.finder")
local uep_log = require("UEP.logger").get()

local M = {}

function M.request(opts)
  opts = opts or {}
  uep_log.debug("--- UEP Provider 'get_project_classes' CALLED (DB) ---")
  
  local deps_flag = opts.deps_flag or "--deep-deps" 

  local db = uep_db.get()
  if not db then return nil end

  -- Load all modules from DB
  local modules_rows = db:eval("SELECT * FROM modules")
  if not modules_rows then return nil end

  local all_modules_map = {}
  for _, row in ipairs(modules_rows) do
      local deep_deps = nil
      if row.deep_dependencies and row.deep_dependencies ~= "" then
          local ok, res = pcall(vim.json.decode, row.deep_dependencies)
          if ok then deep_deps = res end
      end
      
      all_modules_map[row.name] = {
          name = row.name,
          type = row.type,
          category = row.scope, 
          deep_dependencies = deep_deps,
          shallow_dependencies = {} 
      }
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
  
  -- STEP 3: Query Classes from DB
  local mod_names = {}
  for name, _ in pairs(target_module_names) do table.insert(mod_names, "'" .. name .. "'") end
  
  if #mod_names == 0 then return {} end
  
  local sql = string.format([[
        SELECT c.name, c.base_class, c.line_number, c.symbol_type, f.path 
        FROM classes c 
        JOIN files f ON c.file_id = f.id 
        JOIN modules m ON f.module_id = m.id 
        WHERE m.name IN (%s)
    ]], table.concat(mod_names, ","))
    
  local rows = db:eval(sql)
  local merged_header_details = {}
  
  if rows then
      for _, row in ipairs(rows) do
        if not merged_header_details[row.path] then
            merged_header_details[row.path] = { classes = {} }
        end
        table.insert(merged_header_details[row.path].classes, {
            name = row.name,
            base_class = row.base_class,
            line = row.line_number,
            type = row.symbol_type
        })
      end
  end

  local final_count = vim.tbl_count(merged_header_details)
  uep_log.info("Provider: finished (%s). Returning %d headers.", deps_flag, final_count)
  
  return merged_header_details
end

return M
