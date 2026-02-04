-- lua/UEP/cmd/goto_super.lua
local uep_log = require("UEP.logger")
local derived_core = require("UEP.cmd.core.derived")
local uep_utils = require("UEP.cmd.core.utils")
local unl_parser = require("UNL.parser.cpp")
local unl_buf_open = require("UNL.buf.open")
local unl_api = require("UNL.api")

local M = {}

-- バケット構造のメソッドリストをフラットにする
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

-- カーソル位置から「現在のクラス」と「現在の関数」を特定する
local function find_current_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_line = vim.fn.line(".")
    
    local result = unl_parser.parse(bufnr, "UEP")
    
    local target_class = nil
    local target_function = nil
    
    -- ヘッダーの場合
    if result.list then
        for _, cls in ipairs(result.list) do
            if cursor_line >= cls.line and cursor_line <= (cls.end_line or 999999) then
                target_class = cls
                break
            end
        end
    end
    
    -- ソースの場合 (.cpp)
    if not target_class and result.map then
        for class_name, cls in pairs(result.map) do
            local methods = flatten_methods(cls.methods)
            for _, method in ipairs(methods) do
                if method.line == cursor_line then
                    target_class = cls
                    target_function = method
                    break
                elseif cursor_line > method.line then
                    if target_function == nil or method.line > target_function.line then
                        target_class = cls
                        target_function = method
                    end
                end
            end
        end
    end

    -- 関数特定 (ヘッダー内のインライン定義などの場合)
    if target_class and not target_function then
        local methods = flatten_methods(target_class.methods)
        for _, method in ipairs(methods) do
            if cursor_line >= method.line then
                if target_function == nil or method.line > target_function.line then
                    target_function = method
                end
            end
        end
    end

    return target_class, target_function
end

function M.execute(opts)
    local log = uep_log.get()
    opts = opts or {}
    local mode = opts.mode or "definition" -- "definition" or "implementation"
    
    -- 1. コンテキスト取得 (バッファ解析)
    local current_class, current_func = find_current_context()
    
    if not current_class then 
        return log.warn("Could not determine class context at cursor.") 
    end
    if not current_func then 
        return log.warn("Could not determine function context at cursor.") 
    end
    
    local func_name = current_func.name
    local class_name = current_class.name
    
    log.info("Looking for Super::%s (Base of %s) [%s]...", func_name, class_name, mode)

    -- 2. 継承チェーンからシンボルを検索 (DB/RPCで一気に解決)
    unl_api.db.find_symbol_in_inheritance_chain(class_name, func_name, mode, function(res, err)
        if err then
            return log.error("Failed to search inheritance chain: %s", tostring(err))
        end

        if res and res ~= vim.NIL and res.file_path then
            log.info("Found Super::%s in %s", func_name, res.class_name or "parent class")
            
            vim.cmd("normal! m'")
            unl_buf_open.safe({
                file_path = res.file_path,
                open_cmd = "edit",
                plugin_name = "UEP"
            })
            
            -- ウィンドウの切り替えとバッファの展開を待ってからジャンプを実行
            vim.schedule(function()
                local target_line = tonumber(res.line_number) or 0
                
                -- class_name も渡して、.cpp 内での Class::Func 検索を確実にする
                pcall(uep_utils.open_file_and_jump, res.file_path, func_name, target_line, res.class_name)
            end)
        else
            log.warn("Function '%s' not found in any parent class (%s) chain.", func_name, mode)
        end
    end)
end

return M
