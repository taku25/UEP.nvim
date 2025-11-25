-- lua/UEP/cmd/implement_virtual.lua
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")
local derived_core = require("UEP.cmd.core.derived")
local unl_parser = require("UNL.parser.cpp")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")

local M = {}

-- ヘルパー: 引数リストから変数名だけを抽出 (変更なし)
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

-- ヘルパー: コード生成 (変更なし)
local function generate_code(class_name, func_info)
    local return_type = func_info.return_type or "void"
    local func_name = func_info.name
    local params = func_info.params or "()"
    local header_code = string.format("virtual %s %s%s override;", return_type, func_name, params)
    local args = extract_arg_names(params)
    local super_call = (return_type == "void") and string.format("    Super::%s(%s);", func_name, args) or string.format("    return Super::%s(%s);", func_name, args)
    local source_code = string.format([[
%s %s::%s%s
{
%s
}
]], return_type, class_name, func_name, params, super_call)
    return header_code, source_code
end

-- ★ [New] カーソル位置から現在のクラス情報を特定する
local function find_current_class_context(file_path)
    local current_line = vim.fn.line(".")
    local classes = unl_parser.parse_header(file_path)
    
    local best_match = nil
    
    for _, cls in ipairs(classes) do
        local start_line = cls.line
        local end_line = cls.end_line or 999999 -- end_lineが万が一なければ最後までとみなす
        
        -- カーソルがクラス定義の範囲内にあるかチェック
        if current_line >= start_line and current_line <= end_line then
            -- ネストされている場合（インナークラスなど）、より範囲が狭い（開始行が遅い）方を優先
            if best_match == nil or start_line > best_match.line then
                best_match = cls
            end
        end
    end
    
    return best_match
end

function M.execute(opts)
    local log = uep_log.get()
    
    -- 1. ファイルチェック (ヘッダー限定)
    local current_file = vim.api.nvim_buf_get_name(0)
    local ext = vim.fn.fnamemodify(current_file, ":e"):lower()
    
    if ext ~= "h" and ext ~= "hpp" then
        log.warn("Please execute this command in a header file (.h) within a class definition.")
        return
    end

    -- 2. コンテキスト判定 (カーソル位置のクラスを特定)
    local current_class_info = find_current_class_context(current_file)
    
    if not current_class_info then
        log.warn("Could not detect class definition at cursor position.")
        return
    end
    
    local current_class_name = current_class_info.name
    local parent_class_name = current_class_info.base_class
    
    log.info("Detected context: Class '%s' inherits '%s'", current_class_name, tostring(parent_class_name))

    if not parent_class_name then
        log.warn("Class '%s' does not seem to have a base class (or parser failed to detect it).", current_class_name)
        return
    end

    -- 3. 親クラスの定義ファイルを探す
    -- derived_core.get_all_classes を使って全クラスリストから親クラスを探す
    derived_core.get_all_classes({}, function(all_symbols)
        local parent_file_path = nil
        
        if all_symbols then
            for _, sym in ipairs(all_symbols) do
                if sym.class_name == parent_class_name then
                    parent_file_path = sym.file_path
                    break
                end
            end
        end
        
        -- 見つからない場合のフォールバック (UObjectなど)
        if not parent_file_path and parent_class_name == "UObject" then
             -- UObjectは特別な処理が必要かもしれないが、derived_coreで注入済みなら見つかるはず
             log.warn("Definition for parent class '%s' not found in cache.", parent_class_name)
             return
        elseif not parent_file_path then
             log.warn("Definition for parent class '%s' not found in cache. Try :UEP refresh.", parent_class_name)
             return
        end

        -- 4. 親クラスと自クラスをパースして差分を取る
        local parent_classes = unl_parser.parse_header(parent_file_path)
        
        -- 親クラスのメソッド情報を抽出
        local parent_methods = {}
        for _, cls in ipairs(parent_classes) do
            if cls.name == parent_class_name then
                parent_methods = cls.methods
                break
            end
        end

        -- 自分の実装済みメソッド名を抽出 (current_class_info に既にメソッド情報が入っている)
        local my_implemented = {}
        for _, m in ipairs(current_class_info.methods) do
            my_implemented[m.name] = true
        end

        -- 5. オーバーライド候補の抽出
        local candidates = {}
        for _, m in ipairs(parent_methods) do
            if m.is_virtual then
                -- デストラクタ、実装済み、GeneratedBody系を除外
                if not my_implemented[m.name] 
                   and not m.name:match("^~") 
                   and not m.name:match("ReferenceCollectedObjects") -- 内部関数除外例
                then
                    table.insert(candidates, m)
                end
            end
        end

        if #candidates == 0 then
            log.info("No implementable virtual functions found for %s.", parent_class_name)
            return
        end

        -- 6. Picker表示
        local picker_items = {}
        for _, m in ipairs(candidates) do
            table.insert(picker_items, {
                display = string.format("%s %s%s", m.return_type or "void", m.name, m.params),
                value = m,
                kind = "Function"
            })
        end

        unl_picker.pick({
            kind = "uep_virtual_override",
            title = string.format("Override %s :: (Virtual Function)", parent_class_name),
            items = picker_items,
            conf = uep_config.get(),
            preview_enabled = false,
            on_submit = function(selected)
                if not selected then return end
                
                local h_code, cpp_code = generate_code(current_class_name, selected)
                
                -- 7. コード挿入 (ヘッダーのみ)
                -- 現在行の下に挿入
                vim.api.nvim_put({ h_code }, "l", true, true)
                
                -- CPPコードをクリップボードへ
                vim.fn.setreg("+", cpp_code)
                
                log.info("Inserted '%s'. Implementation copied to clipboard.", selected.name)
            end
        })
    end)
end

return M
