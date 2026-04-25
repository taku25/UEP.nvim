-- lua/UEP/cmd/find_usage.lua
-- カーソル下のシンボルが属するクラスの型使用箇所を tree-sitter で検索し、
-- picker でストリーミング表示する。

local unl_api    = require("UNL.api")
local unl_path   = require("UNL.path")
local log        = require("UNL.logging").get("UEP")
local picker     = require("UNL.picker")
local uep_config = require("UEP.config")
local core_utils = require("UEP.cmd.core.utils")

local M = {}

local function make_item(usage)
    local path     = usage.path or ""
    local mod_name = usage.module_name or ""
    local mod_root = usage.module_root or ""
    local line     = usage.line or 0
    local col      = usage.col or 0
    local context  = (usage.context or ""):match("^%s*(.-)%s*$") or ""
    local rel_path = core_utils.create_relative_path(path, mod_root)
    local location = string.format("%s:%d", rel_path, line)
    local label    = mod_name ~= ""
        and string.format("[%s] %s  %s", mod_name, location, context)
        or  string.format("%s  %s", location, context)
    return {
        filename = path,
        lnum     = line,
        col      = col,
        label    = label,
        value    = { file_path = path, lnum = line, col = col },
    }
end

local function show_usages(class_name, header_path, method_name)
    local display_name = method_name
        and string.format("%s::%s", class_name, method_name)
        or  class_name
    local search_label = method_name and "method" or "type"
    log.info("Finding %s usages of: %s...", search_label, display_name)

    picker.open({
        title           = "Find Usages: " .. display_name,
        conf            = uep_config.get(),
        kind            = "uep_find_usage",
        preview_enabled = true,
        source = {
            type = "callback",
            fn = function(push)
                unl_api.db.find_symbol_usages_streaming(
                    class_name,
                    header_path,
                    method_name,
                    function(batch_items)
                        local items = {}
                        for _, usage in ipairs(batch_items or {}) do
                            table.insert(items, make_item(usage))
                        end
                        if #items > 0 then push(items) end
                    end,
                    function(success, result_or_err)
                        if not success then
                            log.error("Find Usage error: %s", tostring(result_or_err))
                        elseif type(result_or_err) == "table" then
                            local total   = result_or_err.total_results or 0
                            local searched = result_or_err.searched_files or 0
                            if total == 0 then
                                log.info("Find Usage: no usages of '%s' found (searched %d files).",
                                    display_name, searched)
                            else
                                log.info("Find Usage: %d usage(s) of '%s' found.", total, display_name)
                            end
                        end
                    end
                )
            end,
        },
        on_confirm = function(selection)
            if not selection then return end
            local path = type(selection) == "table" and selection.file_path
            local lnum = type(selection) == "table" and selection.lnum or 1
            local col  = type(selection) == "table" and selection.col  or 0
            if path then
                vim.cmd("edit " .. vim.fn.fnameescape(unl_path.normalize(path)))
                vim.api.nvim_win_set_cursor(0, { lnum, col })
            end
        end,
    })
end

function M.execute(opts)
    opts = opts or {}

    local bufnr     = 0
    local lines     = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content   = table.concat(lines, "\n")
    local cursor    = vim.api.nvim_win_get_cursor(bufnr)
    local line      = cursor[1] - 1  -- 0-based
    local character = cursor[2]      -- 0-based byte offset
    local file_path = vim.api.nvim_buf_get_name(bufnr)
    if file_path == "" then file_path = nil end

    if content == "" then
        return log.warn("Find Usage: buffer is empty.")
    end

    -- goto_definition で class_name と header_path を解決する
    unl_api.db.goto_definition({
        content   = content,
        line      = line,
        character = character,
        file_path = file_path,
    }, function(result)
        if not result or type(result) ~= "table" then
            log.warn("Find Usage: could not resolve symbol under cursor.")
            return
        end

        local symbol_name = result.symbol_name or ""
        local class_name  = result.class_name  or ""

        -- モード判定:
        --   symbol_name ≠ class_name かつ class_name が非空 → メソッド参照検索
        --   それ以外                                         → 型参照検索
        local method_name = nil
        if symbol_name ~= "" and class_name ~= "" and symbol_name ~= class_name then
            method_name = symbol_name
            -- class_name はスコープとして使用（既にセット済み）
        else
            -- 型検索: class_name が空なら symbol_name で代替
            if class_name == "" then
                class_name = symbol_name
            end
        end

        if class_name == "" then
            log.warn("Find Usage: could not determine class name.")
            return
        end

        -- header_path: .h/.hpp ファイルのみ使用（それ以外は DB フォールバック）
        local header_path = result.file_path
        if header_path then
            local ext = header_path:match("%.([^%.]+)$") or ""
            ext = ext:lower()
            if ext ~= "h" and ext ~= "hpp" then
                header_path = nil
            end
        end

        show_usages(class_name, header_path, method_name)
    end)
end

return M

