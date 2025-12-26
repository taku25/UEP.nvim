local derived_core = require("UEP.cmd.core.derived")
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

    -- 1. 継承チェーンを取得 (DB CTE)
    local function try_get_chain(name, callback)
        derived_core.get_inheritance_chain(name, { scope = "Full" }, callback)
    end

    try_get_chain(class_name, function(chain)
        if chain and #chain > 0 then
            -- Found exact match
            local target_info = chain[1]
            local parents = {}
            for i = 2, #chain do 
                table.insert(parents, { name = chain[i].class_name, header = chain[i].file_path }) 
            end
            on_complete(true, { 
                current = { name = target_info.class_name, header = target_info.file_path },
                parents = parents 
            })
            return
        end

        -- 2. プレフィックス付きを試す
        local prefixes = { "U", "A", "F", "E", "I", "S" }
        local function try_next_prefix(idx)
            if idx > #prefixes then
                uep_log.warn("Class '%s' (and variants) not found in cache.", class_name)
                on_complete(false, nil)
                return
            end
            local candidate = prefixes[idx] .. class_name
            try_get_chain(candidate, function(chain2)
                if chain2 and #chain2 > 0 then
                    local target_info = chain2[1]
                    local parents = {}
                    for i = 2, #chain2 do 
                        table.insert(parents, { name = chain2[i].class_name, header = chain2[i].file_path }) 
                    end
                    on_complete(true, { 
                        current = { name = target_info.class_name, header = target_info.file_path },
                        parents = parents 
                    })
                    return
                end
                try_next_prefix(idx + 1)
            end)
        end
        try_next_prefix(1)
    end)
end

return M
