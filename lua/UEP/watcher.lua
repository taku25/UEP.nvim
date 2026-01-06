-- lua/UEP/watcher.lua
local uep_log = require("UEP.logger")
local uep_db = require("UEP.db.init")
local refresh_modules = require("UEP.cmd.core.refresh_modules")
local unl_finder = require("UNL.finder")
local fs = require("vim.fs")

local M = {}

local watcher_handles = {}
local processing_modules = {}

-- ファイル変更をデバウンスするためのタイマー
local debounce_timers = {}
local DEBOUNCE_MS = 1000 -- 1秒待ってから更新 (頻繁な書き込みを防ぐ)

local function get_module_from_path(file_path)
    local db = uep_db.get()
    if not db then return nil end

    -- パスがマッチする最も長い root_path を持つモジュールを探す
    -- Windowsのパス区切り文字に対応するため、一度正規化したほうが良いが
    -- ここでは簡易的にLIKE検索を行う (必要に応じてパフォーマンスチューニング)
    
    -- file_pathが "C:/Projects/Game/Source/MyModule/Private/MyActor.cpp" の場合
    -- module_root が "C:/Projects/Game/Source/MyModule" であるものを探す
    
    -- SQLiteで文字列操作はコストが高いので、ある程度絞り込むか、
    -- あるいはUNL.api.find_moduleを使う (ただしUNL依存を深めることになる)
    
    -- ここではDBからモジュール一覧をメモリにキャッシュして検索する方が高速かもしれないが、
    -- 非同期更新の頻度は高くないと仮定してDBクエリを投げる
    
    local rows = db:eval([[
        SELECT name, root_path FROM modules 
        ORDER BY length(root_path) DESC
    ]])
    
    if not rows then return nil end

    -- 正規化
    file_path = file_path:gsub("\\", "/"):lower()
    
    for _, row in ipairs(rows) do
        local root = row.root_path:gsub("\\", "/"):lower()
        if file_path:find(root, 1, true) then
            return row.name
        end
    end
    
    return nil
end

local function on_change(err, filename, events, watched_dir)
    if err then
        uep_log.get().error("Watcher error: %s", tostring(err))
        return
    end
    
    if not filename then return end
    
    local full_path = fs.joinpath(watched_dir, filename)
    local ext = vim.fn.fnamemodify(filename, ":e"):lower()
    
    -- 無視するファイル
    if ext == "tmp" or ext == "log" or ext == "txt" then return end
    -- ドットファイル無視
    if filename:match("^%.") then return end

    uep_log.get().debug("File changed: %s (Events: %s)", full_path, vim.inspect(events))

    local module_name = get_module_from_path(full_path)
    if module_name then
        -- デバウンス処理
        if debounce_timers[module_name] then
            debounce_timers[module_name]:stop()
            debounce_timers[module_name]:close()
        end
        
        debounce_timers[module_name] = vim.loop.new_timer()
        debounce_timers[module_name]:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
            debounce_timers[module_name] = nil
            
            if processing_modules[module_name] then
                -- 既に処理中ならスキップ (あるいはキューに入れる？今はスキップ)
                uep_log.get().debug("Module update already in progress for: %s", module_name)
                return
            end
            
            processing_modules[module_name] = true
            uep_log.get().info("Auto-refreshing module: %s due to file change.", module_name)
            
            refresh_modules.update_single_module_cache(module_name, function(ok) 
                processing_modules[module_name] = nil
                if ok then
                    uep_log.get().info("Auto-refresh completed for: %s", module_name)
                else
                    uep_log.get().error("Auto-refresh failed for: %s", module_name)
                end
            end)
        end))
    else
        uep_log.get().trace("Changed file does not belong to any known module: %s", full_path)
    end
end

function M.start()
    M.stop() -- 既存の監視があれば停止
    
    local cwd = vim.loop.cwd()
    local project_info = unl_finder.project.find_project(cwd)
    if not project_info then
        uep_log.get().error("Cannot start watcher: No project found.")
        return
    end
    
    local project_root = project_info.root
    
    -- 監視対象のディレクトリ
    -- 再帰的監視はWindowsでは `recursive = true` が効くことが多いが、
    -- Sourceディレクトリのみに絞るのが安全
    local watch_targets = {
        fs.joinpath(project_root, "Source"),
        fs.joinpath(project_root, "Config"),
        fs.joinpath(project_root, "Plugins"), -- Pluginsも監視
    }

    uep_log.get().info("Starting UEP file watcher for project: %s", project_root)

    for _, path in ipairs(watch_targets) do
        if vim.fn.isdirectory(path) == 1 then
            local handle = vim.loop.new_fs_event()
            -- recursive: true は Windows/macOS でサポートされている。Linuxはinotify制限があるがここでは考慮しない(ユーザーはWindows)
            handle:start(path, { recursive = true }, vim.schedule_wrap(function(err, filename, events) 
                on_change(err, filename, events, path)
            end))
            table.insert(watcher_handles, handle)
            uep_log.get().debug("Watching directory: %s", path)
        end
    end
    
    uep_log.get().info("UEP watcher started.")
end

function M.stop()
    for _, handle in ipairs(watcher_handles) do
        handle:stop()
        if not handle:is_closing() then handle:close() end
    end
    watcher_handles = {}
    
    for _, timer in pairs(debounce_timers) do
        timer:stop()
        if not timer:is_closing() then timer:close() end
    end
    debounce_timers = {}
    
    processing_modules = {}
    uep_log.get().info("UEP watcher stopped.")
end

function M.is_running()
    return #watcher_handles > 0
end

return M
