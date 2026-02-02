local unl_api = require("UNL.api")
local uep_log = require("UEP.logger").get()

local M = {}

function M.request(opts, on_complete)
    local class_name = opts.class_name
    if not class_name or not on_complete then
        uep_log.error("provider.inheritance: Missing class_name or on_complete callback.")
        return
    end

    -- 1. Try to get chain
    unl_api.db.get_inheritance_chain(class_name, function(chain, err)
        if chain and #chain > 0 then
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

        -- 2. Try prefixes
        local prefixes = { "U", "A", "F", "E", "I", "S" }
        local function try_next_prefix(idx)
            if idx > #prefixes then
                on_complete(false, err or "Class not found")
                return
            end
            local candidate = prefixes[idx] .. class_name
            unl_api.db.get_inheritance_chain(candidate, function(chain2)
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