-- lua/UEP/provider/class_context.lua
local derived_core = require("UEP.cmd.core.derived")
local uep_log = require("UEP.logger").get()
local unl_api = require("UNL.api")

local M = {}

-- 非同期処理の実体
local function process_request_async(opts, on_complete)
    local raw_class_name = opts.class_name
    if not raw_class_name then 
        on_complete(false, "No class name provided")
        return 
    end
    
    uep_log.debug("Provider 'uep.get_class_context' (Async) called for: %s", raw_class_name)

    -- ヘルパー: .h / .cpp 解決
    local function resolve_paths(info)
        local header_path = info.file_path
        local cpp_path = nil
        if header_path then
            local ucm_ok, ucm_result = unl_api.provider.request("ucm.get_class_pair", {
                file_path = header_path,
                logger_name = "UEP.class_context"
            })
            if ucm_ok and ucm_result then
                cpp_path = ucm_result.cpp
            end
        end
        return { name = info.class_name, header = header_path, cpp = cpp_path }
    end

    -- ヘルパー: チェーン処理
    local function process_chain(chain)
        local target_info = chain[1]
        local result = {
            current = resolve_paths(target_info),
            parents = {}
        }

        for i = 2, #chain do
            table.insert(result.parents, resolve_paths(chain[i]))
        end

        on_complete(true, result)
    end

    -- 1. 継承チェーンを取得 (DB CTE)
    local function try_get_chain(name, callback)
        derived_core.get_inheritance_chain(name, { scope = "Full" }, callback)
    end

    try_get_chain(raw_class_name, function(chain)
        if chain and #chain > 0 then
            process_chain(chain)
            return
        end

        -- 2. プレフィックス対応
        local prefixes = { "U", "A", "F", "E", "I", "S" }
        local function try_next_prefix(idx)
            if idx > #prefixes then
                uep_log.debug("Class '%s' not found in project.", raw_class_name)
                on_complete(false, "Class not found")
                return
            end
            local candidate = prefixes[idx] .. raw_class_name
            try_get_chain(candidate, function(chain2)
                if chain2 and #chain2 > 0 then
                    uep_log.debug("Resolved class name '%s' -> '%s'", raw_class_name, candidate)
                    process_chain(chain2)
                    return
                end
                try_next_prefix(idx + 1)
            end)
        end
        try_next_prefix(1)
    end)
end

function M.request(opts)
    local on_complete = opts.on_complete
    
    -- 同期呼び出しへのフォールバック (念のため)
    if not on_complete then
        local res_ok, res_val
        process_request_async(opts, function(ok, val) res_ok = ok; res_val = val end)
        if res_ok then return res_val else return nil end
    end

    -- 非同期実行 (vim.scheduleでラップしてメインスレッドの空き時間に処理)
    vim.schedule(function()
        process_request_async(opts, on_complete)
    end)
    
    return nil
end

return M
