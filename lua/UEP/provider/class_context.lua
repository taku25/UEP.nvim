-- lua/UEP/provider/class_context.lua
local parents_core = require("UEP.cmd.core.parents")
local uep_log = require("UEP.logger").get()
local unl_api = require("UNL.api")
local class_provider = require("UEP.provider.class")

local M = {}

-- 非同期処理の実体
local function process_request_async(opts, on_complete)
    local raw_class_name = opts.class_name
    if not raw_class_name then 
        on_complete(false, "No class name provided")
        return 
    end
    
    uep_log.debug("Provider 'uep.get_class_context' (Async) called for: %s", raw_class_name)

    -- 1. 全クラス情報を取得 (確実に動く以前のロジックを採用)
    -- (内部でキャッシュのロードやマージが行われるため、少し重いが確実)
    local header_details_map = class_provider.request({
        scope = "Full", 
        deps_flag = "--deep-deps",
        project_root = opts.project_root
    })

    if not header_details_map then 
        uep_log.warn("Could not retrieve project classes. Run :UEP refresh.")
        on_complete(false, "No header details found")
        return 
    end

    -- 2. 検索用にリスト化 & マップ化
    local all_classes_list = {}
    local target_class_info = nil
    local class_map = {}

    for file_path, details in pairs(header_details_map) do
        if details.classes then
            for _, cls in ipairs(details.classes) do
                cls.file_path = file_path
                table.insert(all_classes_list, cls)
                class_map[cls.class_name] = cls

                if cls.class_name == raw_class_name then
                    target_class_info = cls
                end
            end
        end
    end

    -- 3. プレフィックス対応 (MyActor -> AMyActor)
    if not target_class_info then
        local prefixes = { "U", "A", "F", "E", "I", "S" }
        for _, prefix in ipairs(prefixes) do
            local candidate = prefix .. raw_class_name
            if class_map[candidate] then
                target_class_info = class_map[candidate]
                uep_log.debug("Resolved class name '%s' -> '%s'", raw_class_name, candidate)
                break
            end
        end
    end

    if not target_class_info then 
        uep_log.debug("Class '%s' not found in project.", raw_class_name)
        on_complete(false, "Class not found")
        return 
    end

    -- 4. 継承チェーン取得
    local parents = parents_core.get_inheritance_chain(target_class_info.class_name, all_classes_list)
    
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

    local result = {
        current = resolve_paths(target_class_info),
        parents = {}
    }

    for _, parent_info in ipairs(parents) do
        table.insert(result.parents, resolve_paths(parent_info))
    end

    -- 成功通知
    on_complete(true, result)
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
