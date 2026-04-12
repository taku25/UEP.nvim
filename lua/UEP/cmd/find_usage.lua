-- lua/UEP/cmd/find_usage.lua
local unl_api = require("UNL.api")
local log = require("UNL.logging").get("UEP")
local picker = require("UNL.picker")
local uep_config = require("UEP.config")

local M = {}

local function make_item(usage)
    return {
        filename = usage.path,
        lnum = usage.line,
        col = usage.col or 0,
        label = string.format("%s:%d  %s", usage.path, usage.line, usage.context or ""),
        value = {
            file_path = usage.path,
            lnum = usage.line,
            col = usage.col or 0,
        },
    }
end

function M.execute(opts)
    opts = opts or {}
    local symbol_name = opts.args and opts.args[1]

    if not symbol_name then
        symbol_name = vim.fn.expand("<cword>")
    end

    if not symbol_name or symbol_name == "" then
        log.error("Find Usage: No symbol name provided")
        return
    end

    local current_file = vim.api.nvim_buf_get_name(0)
    if current_file == "" then current_file = nil end

    log.info("Finding usages for: %s...", symbol_name)

    picker.open({
        title = "Find Usages: " .. symbol_name,
        conf = uep_config.get(),
        kind = "uep_find_usage",
        preview_enabled = true,
        source = {
            type = "callback",
            fn = function(push)
                unl_api.db.find_symbol_usages_streaming(
                    symbol_name,
                    current_file,
                    function(batch_items)
                        -- バッチごとに即座に push
                        local items = {}
                        for _, usage in ipairs(batch_items or {}) do
                            table.insert(items, make_item(usage))
                        end
                        if #items > 0 then
                            push(items)
                        end
                    end,
                    function(success, result_or_err)
                        if not success then
                            log.error("Find Usage streaming error: %s", tostring(result_or_err))
                        elseif result_or_err then
                            local searched = (type(result_or_err) == "table" and result_or_err.searched_files) or 0
                            if searched > 0 then
                                log.info("Find Usage complete (searched %d files).", searched)
                            end
                        end
                    end
                )
            end,
        },
        on_confirm = function(selection)
            if not selection then return end
            local data = (type(selection) == "table" and selection.file_path) and selection
                or (type(selection) == "table" and selection.value) or nil
            if data then
                local file_path = data.file_path
                local lnum = data.lnum or 1
                local col = data.col or 0
                if file_path then
                    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
                    vim.api.nvim_win_set_cursor(0, { lnum, col })
                end
            end
        end,
    })
end

return M

