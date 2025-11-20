-- lua/UEP/provider/class_context.lu-- lua/UEP/provider/class_context.lua
local parents_core = require("UEP.cmd.core.parents")
local uep_log = require("UEP.logger").get()
local unl_api = require("UNL.api")

-- 既存のクラスプロバイダーを再利用
local class_provider = require("UEP.provider.class")

local M = {}

function M.request(opts)
    local class_name = opts.class_name
    if not class_name or class_name == "" then return nil end
    
    uep_log.debug("Provider 'uep.get_class_context' called for: %s", class_name)

    -- 1. 全クラス情報を取得 (既存のプロバイダーロジックを再利用)
    -- キャッシュのロードやマージはすべてここで行われるため安全です
    local header_details_map = class_provider.request({
        scope = "Full", -- 全範囲から探す
        deps_flag = "--deep-deps",
        project_root = opts.project_root
    })

    if not header_details_map then 
        uep_log.warn("Could not retrieve project classes. Run :UEP refresh.")
        return nil 
    end

    -- 2. 検索用にリスト化 & マップ化
    -- header_details_map は { "path/to/file.h" = { classes = {...} } } の形式
    local all_classes_list = {}
    local target_class_info = nil

    for file_path, details in pairs(header_details_map) do
        if details.classes then
            for _, cls in ipairs(details.classes) do
                -- ファイルパス情報を付与しておく（親検索で使うため）
                cls.file_path = file_path
                table.insert(all_classes_list, cls)

                -- ターゲットクラスかチェック
                if cls.class_name == class_name then
                    target_class_info = cls
                end
            end
        end
    end

    -- 3. 見つからなかった場合のプレフィックス再検索 (MyActor -> AMyActor)
    if not target_class_info then
        local prefixes = { "A", "U", "F", "E", "I", "S" }
        for _, prefix in ipairs(prefixes) do
            local candidate = prefix .. class_name
            for _, cls in ipairs(all_classes_list) do
                if cls.class_name == candidate then
                    target_class_info = cls
                    uep_log.debug("Resolved class name '%s' -> '%s'", class_name, candidate)
                    goto found
                end
            end
        end
        ::found::
    end

    if not target_class_info then
        uep_log.debug("Class '%s' not found in project.", class_name)
        return nil
    end

    -- 4. 継承チェーンの取得
    local parents = parents_core.get_inheritance_chain(target_class_info.class_name, all_classes_list)
    
    -- ヘルパー: .h / .cpp 解決
    local function resolve_paths(info)
        local header_path = info.file_path
        local cpp_path = nil

        -- UCM連携: .cppを探す
        if header_path then
            local ucm_ok, ucm_result = unl_api.provider.request("ucm.get_class_pair", {
                file_path = header_path,
                logger_name = "UEP.class_context"
            })
            if ucm_ok and ucm_result then
                cpp_path = ucm_result.cpp
            end
        end

        return {
            name = info.class_name,
            header = header_path,
            cpp = cpp_path
        }
    end

    -- 結果の構築
    local result = {
        current = resolve_paths(target_class_info),
        parents = {}
    }

    for _, parent_info in ipairs(parents) do
        -- UObject なども含める
        table.insert(result.parents, resolve_paths(parent_info))
    end

    return result
end

return M
