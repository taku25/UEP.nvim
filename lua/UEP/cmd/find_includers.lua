-- lua/UEP/cmd/find_includers.lua
-- 現在のファイルをインクルードしているファイル一覧をピッカーで表示する。
-- !付き: まずプロジェクト内のファイルをピッカーで選択し、
--        その後選択したファイルをインクルードしているファイル一覧を表示する。

local unl_api  = require("UNL.api")
local unl_path = require("UNL.path")
local log      = require("UNL.logging").get("UEP")
local picker   = require("UNL.picker")
local uep_config = require("UEP.config")
local core_utils = require("UEP.cmd.core.utils")

local M = {}

--- includer アイテムを picker 用に変換する
local function make_item(file_info)
    local path       = file_info.path or ""
    local mod_name   = file_info.module_name or ""
    local mod_root   = file_info.module_root or ""
    local ext        = file_info.extension or ""
    local rel_path   = core_utils.create_relative_path(path, mod_root)
    local label      = mod_name ~= "" and string.format("[%s] %s", mod_name, rel_path) or rel_path
    local icon       = ext == "h" and "H " or ext == "cpp" and "C " or "  "
    return {
        filename = path,
        lnum     = 1,
        col      = 0,
        label    = icon .. label,
        value    = { file_path = path, module_name = mod_name, extension = ext },
    }
end

--- 指定ファイルのインクルーダー一覧をストリーミングピッカーで表示する
local function show_includers(file_path)
    local normalized = unl_path.normalize(file_path)
    local ext = vim.fn.fnamemodify(normalized, ":e"):lower()

    -- .cpp の場合は対応する .h を DB または FS から探して再帰呼び出し
    if ext == "cpp" then
        local stem = vim.fn.fnamemodify(normalized, ":t:r")
        local h_name = stem .. ".h"

        -- まず同ディレクトリの FS で確認
        local h_same_dir = vim.fn.fnamemodify(normalized, ":h") .. "/" .. h_name
        if vim.fn.filereadable(h_same_dir) == 1 then
            vim.schedule(function() show_includers(h_same_dir) end)
            return
        end

        -- FS になければ DB で検索
        unl_api.db.search_files(h_name, function(files)
            if files and #files > 0 then
                -- 完全一致のものを優先
                local found
                for _, f in ipairs(files) do
                    if f.filename == h_name then
                        found = f.path; break
                    end
                end
                found = found or files[1].path
                if found then
                    vim.schedule(function() show_includers(found) end)
                    return
                end
            end
            log.warn("Find Includers: could not resolve .h pair for '%s'.", stem .. ".cpp")
        end)
        return
    end

    local short_name = vim.fn.fnamemodify(normalized, ":t")
    log.info("Finding includers for: %s...", short_name)

    picker.open({
        title           = "Find Includers: " .. short_name,
        conf            = uep_config.get(),
        kind            = "uep_find_includers",
        preview_enabled = true,
        source = {
            type = "callback",
            fn = function(push)
                unl_api.db.find_includers_streaming(
                    normalized,
                    function(batch_items)
                        local items = {}
                        for _, info in ipairs(batch_items or {}) do
                            table.insert(items, make_item(info))
                        end
                        if #items > 0 then push(items) end
                    end,
                    function(success, result_or_err)
                        if not success then
                            log.error("Find Includers error: %s", tostring(result_or_err))
                        elseif type(result_or_err) == "table" then
                            if result_or_err.found_target == false then
                                log.warn("Find Includers: '%s' is not in the DB. Try :UNL refresh.", short_name)
                            elseif (result_or_err.total_files or 0) == 0 then
                                log.info("Find Includers: no files include '%s'.", short_name)
                            else
                                log.info("Find Includers: found %d file(s) including '%s'.",
                                    result_or_err.total_files, short_name)
                            end
                        end
                    end
                )
            end,
        },
        on_confirm = function(selection)
            if not selection then return end
            local data = (type(selection) == "table" and selection.value) or nil
            local path  = data and data.file_path or (type(selection) == "string" and selection)
            if path then
                vim.cmd("edit " .. vim.fn.fnameescape(path))
            end
        end,
    })
end

--- !付き: プロジェクトの全ファイルからターゲットを選んで includer を検索する
local function pick_then_show_includers()
    unl_api.db.get_all_file_paths(function(paths, err)
        if err or not paths or #paths == 0 then
            log.warn("Find Includers: no files in DB. Try :UNL refresh first.")
            return
        end

        local items = {}
        for _, p in ipairs(paths) do
            table.insert(items, {
                display  = p,
                filename = p,
                value    = p,
            })
        end

        picker.open({
            title           = "Select file to find includers",
            conf            = uep_config.get(),
            kind            = "uep_find_includers_pick",
            preview_enabled = true,
            source = {
                type = "callback",
                fn   = function(push) push(items) end,
            },
            on_confirm = function(selection)
                if not selection then return end
                local selected_path = (type(selection) == "table" and selection.value)
                    or (type(selection) == "string" and selection)
                if selected_path then
                    -- 少し遅延させて前のピッカーが閉じてから次を開く
                    vim.schedule(function()
                        show_includers(selected_path)
                    end)
                end
            end,
        })
    end)
end

function M.execute(opts)
    opts = opts or {}

    -- !付き: ファイルピッカーからターゲットを選択
    if opts.has_bang then
        pick_then_show_includers()
        return
    end

    -- 引数でファイルパスを指定
    local file_path = opts.args and opts.args[1]

    -- 引数なし: 現在バッファのファイルを使用
    if not file_path or file_path == "" then
        file_path = vim.api.nvim_buf_get_name(0)
    end

    if not file_path or file_path == "" then
        log.error("Find Includers: no file path (open a file or provide a path as argument)")
        return
    end

    show_includers(file_path)
end

return M
