-- lua/UEP/cmd/find_usage.lua
local unl_api = require("UNL.api")
local log = require("UNL.logging").get("UEP")
local picker = require("UNL.picker")

local M = {}

-- 将来的に「精密検証」を挟むためのフィルター関数（プレースホルダ）
local function verify_usages(usages, symbol_name, callback)
    -- 現状はサーバーからきた結果（名前一致）をそのまま返す
    -- 将来的にここで呼び出し元のTree-sitter解析などを行い、
    -- 本当にそのシンボルを呼んでいるかチェックするロジックを挟める
    callback(usages)
end

function M.execute(opts)
    opts = opts or {}
    local symbol_name = opts.args and opts.args[1]
    
    if not symbol_name then
        -- カーソル下の単語を取得
        symbol_name = vim.fn.expand("<cword>")
    end

    if not symbol_name or symbol_name == "" then
        log.error("Find Usage: No symbol name provided or found under cursor.")
        return
    end

    log.info("Finding C++ usages for: %s...", symbol_name)

    unl_api.db.find_symbol_usages(symbol_name, function(results, err)
        if err then
            log.error("Find Usage failed: %s", tostring(err))
            return
        end

        if not results or #results == 0 then
            log.info("No C++ usages found for '%s'.", symbol_name)
            return
        end

        -- 精密検証ステップ（将来の拡張用）
        verify_usages(results, symbol_name, function(verified_results)
            if #verified_results == 0 then
                log.info("No verified C++ usages found for '%s'.", symbol_name)
                return
            end

            -- UNL.picker で表示
            local items = {}
            for _, usage in ipairs(verified_results) do
                table.insert(items, {
                    label = string.format("%s:%d", usage.path, usage.line),
                    path = usage.path,
                    line = usage.line,
                    value = usage,
                })
            end

            picker.open({
                title = "C++ Usages: " .. symbol_name,
                items = items,
                on_confirm = function(selection)
                    if not selection then return end
                    local item = type(selection) == "table" and selection or selection[1]
                    if item and item.path then
                        vim.cmd("edit " .. vim.fn.fnameescape(item.path))
                        vim.api.nvim_win_set_cursor(0, { item.line, 0 })
                    end
                end,
                preview_enabled = true,
            })
        end)
    end)
end

return M
