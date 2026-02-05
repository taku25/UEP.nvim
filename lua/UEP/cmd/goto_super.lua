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

-- カーソル位置から「現在のクラス」と「現在の関数」を特定する (サーバー解析版)
local function find_current_context(callback)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    
    unl_api.db.parse_buffer(nil, function(res)
        if not res or not res.symbols then return callback(nil, nil) end
        
        local target_class = nil
        local target_function = nil
        
        for _, cls in ipairs(res.symbols) do
            if cursor_line >= (cls.line or 0) and cursor_line <= (cls.end_line or 999999) then
                target_class = cls
                -- 関数特定
                local methods = flatten_methods(cls.methods)
                for _, method in ipairs(methods) do
                    local m_start = method.line or 0
                    local m_end = method.end_line or m_start -- end_lineがない場合は1行のみとみなす
                    
                    if cursor_line >= m_start and cursor_line <= m_end then
                        target_function = method
                        break
                    end
                end
                break
            end
        end
        callback(target_class, target_function)
    end)
end

function M.execute(opts)
    local log = uep_log.get()
    opts = opts or {}
    local mode = opts.mode or "definition" -- "definition" or "implementation"
    
    -- 1. コンテキスト取得 (サーバー解析)
    find_current_context(function(current_class, current_func)
        if not current_class then return log.warn("Could not determine class context at cursor.") end
        
        local class_name = current_class.name
        local word_under_cursor = vim.fn.expand('<cword>')

        -- クラス名の上にいる場合は、関数の中にいても「親クラス」へのジャンプを優先する
        if word_under_cursor == class_name then
            current_func = nil
        end

        -- 関数がない場合は親クラスのヘッダーに飛ぶ
        if not current_func then
            log.info("No function at cursor. Jumping to parent class header of %s...", class_name)
            unl_api.db.get_inheritance_chain(class_name, function(chain, err)
                if err then return log.error("Failed to get parent classes: %s", tostring(err)) end
                -- chain[1] は自分自身、chain[2] が直接の親
                if chain and #chain >= 2 then
                    local parent = chain[2]
                    if parent.file_path then
                        log.info("Jumping to parent class: %s", parent.class_name)
                        vim.cmd("normal! m'")
                        unl_buf_open.safe({
                            file_path = parent.file_path,
                            open_cmd = "edit",
                            plugin_name = "UEP"
                        })
                        vim.schedule(function()
                            uep_utils.open_file_and_jump(parent.file_path, parent.class_name, parent.line_number)
                        end)
                    end
                else
                    log.warn("No parent class found for %s", class_name)
                end
            end)
            return
        end
        
        local func_name = current_func.name
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
    end)
end

return M
