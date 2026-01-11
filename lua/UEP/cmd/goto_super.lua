-- lua/UEP/cmd/goto_super.lua
local uep_log = require("UEP.logger")
local derived_core = require("UEP.cmd.core.derived")
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
    
    -- 1. コンテキスト取得
    local current_class, current_func = find_current_context()
    
    if not current_class then return log.warn("Could not determine class context at cursor.") end
    if not current_func then return log.warn("Could not determine function context at cursor.") end
    
    local func_name = current_func.name
    local class_name = current_class.name
    
    if func_name == class_name or func_name == "~"..class_name then
        log.info("Super jump for Constructor/Destructor is not fully supported yet.")
    end

    log.info("Looking for Super::%s (Base of %s) [%s]...", func_name, class_name, mode)

    -- 2. 親クラス情報を取得 (DB CTE)
    derived_core.get_inheritance_chain(class_name, { scope = "Full" }, function(parents_chain)
        if not parents_chain then return log.error("Failed to get inheritance chain. Run :UEP refresh.") end
        if #parents_chain == 0 then return log.warn("Class '%s' has no known parent classes in cache.", class_name) end

        -- 4. 親クラスを近い順に走査
        for _, parent_info in ipairs(parents_chain) do
            local header_path = parent_info.file_path
            
            -- 親クラスの定義(ヘッダー)が見つかった場合
            if header_path and vim.fn.filereadable(header_path) == 1 then
                
                -- モード分岐: 定義(ヘッダー)か、実装(.cpp)か
                local target_file_path = header_path
                
                if mode == "implementation" then
                    -- .h から .cpp を探す
                    local ucm_ok, pair = unl_api.provider.request("ucm.get_class_pair", { file_path = header_path })
                    if ucm_ok and pair and pair.cpp then
                        target_file_path = pair.cpp
                    else
                        log.debug("No implementation file found for %s, falling back to header.", parent_info.class_name)
                        -- .cppがない場合はヘッダー内実装の可能性があるのでヘッダーを検索
                    end
                end

                -- ターゲットファイルをパースして関数を探す
                local p_result = unl_parser.parse(target_file_path, "UEP")
                
                -- cppファイルの場合、クラス名が名前空間的に使われているので map から探す
                -- ヘッダーの場合、list から探す (find_best_match_class 利用)
                local p_class_data = nil
                
                if mode == "implementation" and target_file_path:match("%.cpp$") then
                    p_class_data = p_result.map[parent_info.class_name]
                else
                    p_class_data = unl_parser.find_best_match_class(p_result, parent_info.class_name)
                end
                
                if p_class_data then
                    local p_methods = flatten_methods(p_class_data.methods)
                    
                    for _, m in ipairs(p_methods) do
                        if m.name == func_name then
                            log.info("Found Super::%s in %s", func_name, parent_info.class_name)
                            
                            vim.cmd("normal! m'")
                            unl_buf_open.safe({
                                file_path = target_file_path,
                                open_cmd = "edit",
                                plugin_name = "UEP"
                            })
                            vim.api.nvim_win_set_cursor(0, { m.line, 0 })
                            vim.cmd("normal! zz")
                            return
                        end
                    end
                end
            end
        end
        
        log.warn("Function '%s' not found in any parent class (%s) chain.", func_name, mode)
    end)
end

return M
