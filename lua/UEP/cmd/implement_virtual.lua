-- lua/UEP/cmd/implement_virtual.lua
local uep_log = require("UEP.logger")
local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")

local unl_parser
do
  local ok, mod = pcall(require, "UNL.parser.cpp")
  if ok then unl_parser = mod end
end

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
-- 解析ロジック
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

local function find_current_class_context()
    if not unl_parser then return nil end
    local current_line = vim.fn.line(".")
    local bufnr = vim.api.nvim_get_current_buf()
    
    local parse_result = unl_parser.parse(bufnr, "UEP")
    local classes = parse_result.list or {}
    
    local best_match = nil
    for _, cls in ipairs(classes) do
        local start_line = cls.line
        local end_line = cls.end_line or 999999
        
        if current_line >= start_line and current_line <= end_line then
            if best_match == nil or start_line > best_match.line then
                best_match = cls
            end
        end
    end
    return best_match
end

-- ============================================================
-- メインコマンド
-- ============================================================

function M.execute(opts)
    local log = uep_log.get()
    
    if not unl_parser then
        log.error("UNL.parser.cpp not found. Cannot execute virtual_override.")
        return
    end

    -- 1. ヘッダーファイルチェック
    local current_file = vim.api.nvim_buf_get_name(0)
    local ext = vim.fn.fnamemodify(current_file, ":e"):lower()
    if ext ~= "h" and ext ~= "hpp" then
        log.warn("Please execute this command in a header file (.h).")
        return
    end

    -- 2. 現在のクラスを特定
    local current_class_info = find_current_class_context()
    if not current_class_info then
        log.warn("Could not detect class definition at cursor. Ensure cursor is inside a class body.")
        return
    end
    
    local current_class_name = current_class_info.name
    
    log.info("Context: Class '%s' (Base: %s)", current_class_name, tostring(current_class_info.base_class))

    -- 3. 継承チェーンを取得 (DB CTE)
    derived_core.get_inheritance_chain(current_class_name, { scope = "Full" }, function(parents_chain)
        if not parents_chain then return log.error("Failed to get inheritance chain.") end
        if #parents_chain == 0 then
            log.warn("No parent classes found for '%s' in cache.", current_class_name)
            return
        end
        
        local my_methods = flatten_methods(current_class_info.methods)
        local my_implemented = {}
        for _, m in ipairs(my_methods) do my_implemented[m.name] = true end

        local candidates = {}
        local seen_funcs = {}

        -- 5. 継承チェーンを巡回して virtual 関数を収集
        for _, parent_info in ipairs(parents_chain) do
            local file_path = parent_info.file_path
            if file_path and vim.fn.filereadable(file_path) == 1 then
                
                local parent_parse_result = unl_parser.parse(file_path, "UEP")
                local target_parent_data = unl_parser.find_best_match_class(parent_parse_result, parent_info.class_name)
                
                if target_parent_data then
                    local p_methods = flatten_methods(target_parent_data.methods)
                    
                    for _, m in ipairs(p_methods) do
                        if m.is_virtual 
                           and not my_implemented[m.name] 
                           and not seen_funcs[m.name]
                           and not m.name:match("^~") 
                           and not m.name:match("ReferenceCollectedObjects") 
                        then
                            m.declared_in = parent_info.class_name
                            table.insert(candidates, m)
                            seen_funcs[m.name] = true
                        end
                    end
                end
            end
        end

        if #candidates == 0 then
            log.info("No implementable virtual functions found in inheritance chain.")
            return
        end

        table.sort(candidates, function(a, b) return a.name < b.name end)

        -- 6. Picker表示
        local picker_items = {}
        for _, m in ipairs(candidates) do
            table.insert(picker_items, {
                display = string.format("%s %s%s  [%s]", m.return_type or "void", m.name, m.params, m.declared_in),
                value = m,
                kind = "Function",
                
                -- ★追加: プレビュー用の位置情報 (各種Pickerに対応)
                filename = m.file_path, 
                lnum = m.line,
                row = m.line, -- FzfLuaなど用
                line = m.line, -- 念のため
                col = 1       -- 列番号
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
end

return M
