-- lua/UEP/cmd/rename_symbol.lua
-- カーソル下シンボルを find_usage と同じ検索スコープで一括リネームする。
-- ファイル名の変更は行わない（Unreal Engine の Redirector 等はユーザー責務）。

local unl_api    = require("UNL.api")
local unl_path   = require("UNL.path")
local log        = require("UNL.logging").get("UEP")
local progress   = require("UNL.backend.progress")
local uep_config = require("UEP.config")

local M = {}

-- ファイル group をリネームして保存する。
-- 進捗は progress オブジェクトで表示。
local function do_rename(old_name, new_name, usages, definition_file, conf)
    -- usage をファイルごとにグループ化
    local by_file = {}
    for _, u in ipairs(usages) do
        local p = u.path
        if p then
            if not by_file[p] then by_file[p] = {} end
            table.insert(by_file[p], u)
        end
    end

    -- definition_file（ヘッダー自体）はインクルーダー一覧に含まれない
    -- → 別途ホール・ワード置換で処理する
    local process_def_file = definition_file and not by_file[definition_file]

    local files      = vim.tbl_keys(by_file)
    local total      = #files + (process_def_file and 1 or 0)
    if total == 0 then
        log.info("Rename Symbol: no files to modify.")
        return
    end

    local prog = progress.create(conf, {
        title       = string.format("Rename: %s → %s", old_name, new_name),
        client_name = "UEP",
        purpose     = "rename",
    })
    prog:stage_define("files", total)

    local done_count    = 0
    local changed_count = 0

    -- 使用箇所ファイルを精密置換（col ベース）
    for _, fpath in ipairs(files) do
        local norm      = unl_path.normalize(fpath)
        local file_usages = by_file[fpath]

        -- 同一ファイル内の置換は行番号降順→列番号降順で行い offset ずれを防ぐ
        table.sort(file_usages, function(a, b)
            if a.line ~= b.line then return a.line > b.line end
            return (a.col or 0) > (b.col or 0)
        end)

        local lines = vim.fn.readfile(norm)
        if lines and #lines > 0 then
            local modified = false
            for _, u in ipairs(file_usages) do
                local li = u.line          -- 1-based
                local co = u.col or 0     -- 0-based byte offset
                if li >= 1 and li <= #lines then
                    local lc     = lines[li]
                    local actual = lc:sub(co + 1, co + #old_name)
                    if actual == old_name then
                        lines[li]     = lc:sub(1, co) .. new_name .. lc:sub(co + #old_name + 1)
                        modified      = true
                        changed_count = changed_count + 1
                    end
                end
            end
            if modified then
                vim.fn.writefile(lines, norm)
            end
        end

        done_count = done_count + 1
        prog:stage_update("files", done_count, total, vim.fn.fnamemodify(norm, ":t"))
    end

    -- 定義ファイルをホール・ワード置換（宣言・定義行を含む）
    if process_def_file then
        local norm  = unl_path.normalize(definition_file)
        local lines = vim.fn.readfile(norm)
        if lines and #lines > 0 then
            local modified = false
            -- Lua フロンティアパターンで識別子境界を確保
            local pattern = "%f[%w_]" .. vim.pesc(old_name) .. "%f[^%w_]"
            for i, line in ipairs(lines) do
                local replaced, n = line:gsub(pattern, new_name)
                if n > 0 then
                    lines[i]      = replaced
                    modified      = true
                    changed_count = changed_count + n
                end
            end
            if modified then
                vim.fn.writefile(lines, norm)
            end
        end
        done_count = done_count + 1
        prog:stage_update("files", done_count, total, vim.fn.fnamemodify(norm, ":t"))
    end

    prog:finish(true)

    -- 開いているバッファを再読み込み
    vim.cmd("checktime")

    log.info(
        "Rename: '%s' → '%s' — %d replacement(s) in %d file(s).",
        old_name, new_name, changed_count, total
    )
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
        return log.warn("Rename Symbol: buffer is empty.")
    end

    -- goto_definition でシンボルとクラスを解決
    unl_api.db.goto_definition({
        content   = content,
        line      = line,
        character = character,
        file_path = file_path,
    }, function(result)
        if not result or type(result) ~= "table" then
            return log.warn("Rename Symbol: could not resolve symbol under cursor.")
        end

        local symbol_name = result.symbol_name or ""
        local class_name  = result.class_name  or ""

        -- find_usage と同じモード判定
        local old_name, search_class, method_name
        if symbol_name ~= "" and class_name ~= "" and symbol_name ~= class_name then
            -- メソッドモード
            old_name     = symbol_name
            search_class = class_name
            method_name  = symbol_name
        else
            -- 型モード
            old_name     = class_name ~= "" and class_name or symbol_name
            search_class = old_name
            method_name  = nil
        end

        if old_name == "" then
            return log.warn("Rename Symbol: could not determine symbol name.")
        end

        -- ヘッダーパスを解決（.h / .hpp のみ）
        local header_path = result.file_path
        if header_path then
            local ext = (header_path:match("%.([^%.]+)$") or ""):lower()
            if ext ~= "h" and ext ~= "hpp" then
                header_path = nil
            end
        end

        -- 現在名を事前入力した状態で新名前を尋ねる
        vim.ui.input({
            prompt  = string.format("Rename '%s' to: ", old_name),
            default = old_name,
        }, function(new_name)
            if not new_name or vim.trim(new_name) == "" or new_name == old_name then
                return log.info("Rename Symbol: cancelled.")
            end
            new_name = vim.trim(new_name)

            log.info("Rename Symbol: collecting usages of '%s'...", old_name)

            local conf = uep_config.get()

            -- 使用箇所を全件収集してからリネーム
            local all_usages = {}
            unl_api.db.find_symbol_usages_streaming(
                search_class,
                header_path,
                method_name,
                function(batch)
                    for _, u in ipairs(batch or {}) do
                        table.insert(all_usages, u)
                    end
                end,
                function(success, _)
                    if not success then
                        return log.error("Rename Symbol: failed to fetch usages.")
                    end

                    vim.schedule(function()
                        do_rename(old_name, new_name, all_usages, header_path, conf)
                    end)
                end
            )
        end)
    end)
end

return M
