-- lua/UEP/provider/class_context.lua
local parents_core = require("UEP.cmd.core.parents")
local uep_log = require("UEP.logger").get()
local unl_api = require("UNL.api")
local class_provider = require("UEP.provider.class")
local symbol_cache_mod = require("UEP.cache.symbols")

local M = {}

local function load_any_symbol_cache()
    local scopes = { "Game", "Runtime", "Engine", "Full", "Developer", "Editor", "game", "runtime", "engine", "full", "developer", "editor" }
    local deps = { "--deep-deps", "--shallow-deps", "--no-deps" }

    for _, scope in ipairs(scopes) do
        for _, dep in ipairs(deps) do
            local cache = symbol_cache_mod.load(scope, dep)
            if cache and next(cache) then
                return cache
            end
        end
    end
    return nil
end

-- 非同期処理本体
local function process_request_async(opts, on_complete)
    local raw_class_name = opts.class_name
    if not raw_class_name then 
        on_complete(false, "No class name provided")
        return 
    end
    
    uep_log.debug("Provider 'uep.get_class_context' (Async) called for: %s", raw_class_name)

    -- 1. キャッシュロード
    local symbol_cache = load_any_symbol_cache()
    
    if not symbol_cache then 
        uep_log.info("Symbol cache not found. Attempting to generate...")
        -- ここも同期だと重いが、プロバイダー呼び出しなので一旦許容
        -- 本来はここも非同期チェーンにすべき
        class_provider.request({ scope = "Full", deps_flag = "--deep-deps", project_root = opts.project_root })
        symbol_cache = load_any_symbol_cache()
    end

    if not symbol_cache then 
        on_complete(false, "Symbol cache could not be loaded.")
        return 
    end

    -- 2. クラス検索
    local target_class_info = nil
    local class_map = {}
    for _, sym in ipairs(symbol_cache) do
        class_map[sym.class_name] = sym
    end

    if class_map[raw_class_name] then
        target_class_info = class_map[raw_class_name]
    else
        local prefixes = { "U", "A", "F", "E", "I", "S" }
        for _, prefix in ipairs(prefixes) do
            local candidate = prefix .. raw_class_name
            if class_map[candidate] then
                target_class_info = class_map[candidate]
                break
            end
        end
    end

    if not target_class_info then 
        on_complete(false, "Class not found in cache.")
        return 
    end

    -- 3. 継承チェーン取得
    local parents = parents_core.get_inheritance_chain(target_class_info.class_name, symbol_cache)
    
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

    -- 完了通知
    on_complete(true, result)
end

function M.request(opts)
    -- コールバック関数を取得
    local on_complete = opts.on_complete
    if not on_complete then
        uep_log.warn("uep.get_class_context called without on_complete callback. Running synchronously (deprecated).")
        -- フォールバック: 同期実行して返す（旧仕様互換）
        local res_ok, res_val
        process_request_async(opts, function(ok, val) res_ok = ok; res_val = val end)
        if res_ok then return res_val else return nil end
    end

    -- ★ 非同期実行: メインループをブロックしないように schedule で実行
    vim.schedule(function()
        process_request_async(opts, on_complete)
    end)
    
    -- 非同期モードなので即座に nil を返す（結果はコールバックで）
    return nil
end

return M
