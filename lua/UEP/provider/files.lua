local files_core = require("UEP.cmd.core.files")
local core_utils = require("UEP.cmd.core.utils") -- ★追加
local uep_log = require("UEP.logger").get()

local M = {}

-- capability: "uep.get_project_items"
-- @param opts { scope = "game"|"full" }
-- @param on_complete function(ok, items)
function M.request(opts, on_complete)
    if not on_complete then
        uep_log.error("provider.files: 'on_complete' callback is required.")
        return
    end

    -- ★変更: get_all_cached_items ではなく、詳細情報を持つ get_files を使う
    files_core.get_files(opts, function(ok, files_with_context)
        if not ok then
            on_complete(false, "Failed to get files from UEP core.")
            return
        end

        local items = {}
        -- ここで一括して表示名(相対パス)を作成する
        for _, data in ipairs(files_with_context) do
            local display_text = data.file_path
            
            -- モジュールルートが分かっているなら、それを使って高速に相対パス化
            if data.module_root and data.module_name then
                local rel = core_utils.create_relative_path(data.file_path, data.module_root)
                -- UEP files と同じ "ModuleName/RelativePath" 形式にする
                display_text = string.format("%s/%s", data.module_name, rel)
            end

            table.insert(items, {
                path = data.file_path,
                display = display_text, -- ★整形済みテキストを追加
                type = "file" -- get_files は現状ファイルのみ返す仕様
            })
        end
        
        on_complete(true, items)
    end)
end

return M
