local derived_core = require("UEP.cmd.core.derived")
local parents_core = require("UEP.cmd.core.parents")
local uep_log = require("UEP.logger").get()

local M = {}

---
-- UNX向けに、指定されたクラスの継承チェーンと自身の情報を返す
-- ロジックは :UEP find_parents と完全に同じものを使用
function M.request(opts)
    local class_name = opts.class_name
    local on_complete = opts.on_complete

    if not class_name or not on_complete then
        uep_log.error("provider.inheritance: Missing class_name or on_complete callback.")
        return
    end

    uep_log.debug("Provider 'uep.get_inheritance_chain' called for: %s", class_name)

    -- 1. 全クラス情報を取得 (find_parents と同じ opts={scope="Full"} )
    derived_core.get_all_classes({ scope = "Full", deps_flag = "--deep-deps" }, function(all_classes)
        if not all_classes then
            uep_log.warn("Could not retrieve class info. Cache might be empty.")
            on_complete(false, nil)
            return
        end

        -- 2. ターゲットクラス自身の情報を特定
        local target_info = nil
        for _, info in ipairs(all_classes) do
            if info.class_name == class_name then
                target_info = info
                break
            end
        end

        -- ヒットしなければプレフィックス付き (ACharacter, UObject etc) も試す
        if not target_info then
            local prefixes = { "U", "A", "F", "E", "I", "S" }
            for _, prefix in ipairs(prefixes) do
                local candidate = prefix .. class_name
                for _, info in ipairs(all_classes) do
                    if info.class_name == candidate then
                        target_info = info
                        break
                    end
                end
                if target_info then break end
            end
        end

        if not target_info then
            uep_log.warn("Class '%s' not found in project cache.", class_name)
            on_complete(false, nil)
            return
        end

        -- 3. 継承チェーンを取得 (find_parents と同じコアロジック)
        local chain = parents_core.get_inheritance_chain(target_info.class_name, all_classes)

        -- 4. UNXのパーサーが期待する形式 ({ current=..., parents={...} }) に整形
        local result = {
            current = {
                name = target_info.class_name,
                header = target_info.file_path,
            },
            parents = {}
        }

        for _, parent_info in ipairs(chain) do
            table.insert(result.parents, {
                name = parent_info.class_name,
                header = parent_info.file_path,
            })
        end

        uep_log.info("Inheritance resolved for %s. Found %d parents.", target_info.class_name, #result.parents)
        on_complete(true, result)
    end)
end

return M
