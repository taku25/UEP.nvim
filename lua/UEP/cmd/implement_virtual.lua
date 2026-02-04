-- lua/UEP/cmd/implement_virtual.lua
local uep_log = require("UEP.logger")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local unl_api = require("UNL.api")

local M = {}

-- ============================================================
-- コード生成ヘルパー
-- ============================================================

local function extract_arg_names(params_str)
  if not params_str or params_str == "()" or params_str == "" then return "" end
  local content = params_str:match("^%s*%(?(.-)%)?%s*$")
  if not content or content == "" then return "" end
  local args = {}
  for param in content:gmatch("[^,]+") do
    local param_no_default = param:gsub("=.*$", ""):gsub("%[.*%]", "")
    local name = param_no_default:match("(%w+)%s*$")
    if name then table.insert(args, name) end
  end
  return table.concat(args, ", ")
end

local function generate_code(class_name, func_info)
  local return_type = func_info.return_type or "void"
  if not return_type or return_type == "" then return_type = "void" end
  local func_name = func_info.name
  local params = func_info.params or "()"
  local header_code = string.format("virtual %s %s%s override;", return_type, func_name, params)
  local args = extract_arg_names(params)
  local super_call = (return_type == "void") 
    and string.format("    Super::%s(%s);", func_name, args) 
    or string.format("    return Super::%s(%s);", func_name, args)
  local source_code = string.format([[
%s %s::%s%s
{
%s
}
]], return_type, class_name, func_name, params, super_call)
  return header_code, source_code
end

-- ============================================================
-- 解析ロジック (DB/RPC版)
-- ============================================================

local function flatten_methods(methods_bucket)
  local flat = {}
  if not methods_bucket then return flat end
  for _, access in ipairs({"public", "protected", "private", "impl"}) do
    if methods_bucket[access] then
      for _, m in ipairs(methods_bucket[access]) do
        table.insert(flat, m)
      end
    end
  end
  return flat
end

-- 現在のバッファのクラス情報をサーバーでリアルタイム解析して取得
local function get_current_class_from_buffer(line, callback)
  unl_api.db.parse_buffer(nil, function(res)
    if not res or not res.symbols then return callback(nil) end
    
    local best_match = nil
    for _, cls in ipairs(res.symbols) do
      local start_line = cls.line or 0
      local end_line = cls.end_line or 999999
      if line >= start_line and line <= end_line then
        if best_match == nil or start_line > best_match.line then
          best_match = cls
        end
      end
    end
    callback(best_match)
  end)
end

-- ============================================================
-- メインコマンド
-- ============================================================

function M.execute(opts)
  local log = uep_log.get()
  local current_file = vim.api.nvim_buf_get_name(0)
  local ext = vim.fn.fnamemodify(current_file, ":e"):lower()
  if ext ~= "h" and ext ~= "hpp" then
    log.warn("Please execute this command in a header file (.h).")
    return
  end

  local current_line = vim.fn.line(".")
  get_current_class_from_buffer(current_line, function(current_class_info)
    if not current_class_info then
      log.warn("Could not detect class definition at cursor.")
      return
    end
    local current_class_name = current_class_info.name
    log.info("Context: Class '%s' (Base: %s)", current_class_name, tostring(current_class_info.base_class))

    unl_api.db.get_virtual_functions_in_inheritance_chain(current_class_name, function(candidates, err)
      if err then return log.error("Failed to get virtual functions: %s", tostring(err)) end
      if not candidates or #candidates == 0 then
        log.info("No implementable virtual functions found in inheritance chain.")
        return
      end

      local my_methods = flatten_methods(current_class_info.methods)
      local my_implemented = {}
      for _, m in ipairs(my_methods) do my_implemented[m.name] = true end

      local filtered_candidates = {}
      local seen_funcs = {}
      for _, m in ipairs(candidates) do
        if not my_implemented[m.name] and not seen_funcs[m.name] and not m.name:match("^~") 
           and not m.name:match("ReferenceCollectedObjects") then
          table.insert(filtered_candidates, m)
          seen_funcs[m.name] = true
        end
      end

      if #filtered_candidates == 0 then
        log.info("All virtual functions are already implemented.")
        return
      end

      local picker_items = {}
      for _, m in ipairs(filtered_candidates) do
        table.insert(picker_items, {
          display = string.format("%s %s%s  [%s]", m.return_type or "void", m.name, m.params or "()", m.declared_in),
          value = m,
          kind = "Function",
          filename = m.file_path, 
          lnum = m.line,
          col = 1
        })
      end

      unl_picker.pick({
        kind = "uep_virtual_override",
        title = string.format("Override Virtual Function (Current: %s)", current_class_name),
        items = picker_items,
        conf = uep_config.get(),
        preview_enabled = true, 
        on_submit = function(selected)
          if not selected then return end
          local h_code, cpp_code = generate_code(current_class_name, selected)
          vim.api.nvim_put({ h_code }, "l", true, true)
          vim.fn.setreg("+", cpp_code)
          log.info("Inserted override for '%s'. Implementation copied to clipboard.", selected.name)
        end
      })
    end)
  end)
end

return M
