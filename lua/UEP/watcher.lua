-- lua/UEP/watcher.lua
local uep_log = require("UEP.logger")
local uep_db = require("UEP.db.init")
local refresh_modules = require("UEP.cmd.core.refresh_modules")
local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local fs = require("vim.fs")

local M = {}

local watcher_handles = {}
local processing_modules = {}
local cached_modules = nil

-- ファイル変更をデバウンスするためのタイマー
local debounce_timers = {}
local DEBOUNCE_MS = 1000 

-- スロットリング用: 同じファイルへのイベントは一定時間無視する
local last_event_times = {}
local THROTTLE_MS = 50 

-- 変更されたファイルをモジュールごとに記録 (一括更新か個別更新かの判断用)
local pending_changes = {} -- { [module_name] = { [filepath] = true } }
local BULK_UPDATE_THRESHOLD = 5 -- 変更ファイル数がこれ以上ならモジュール全体を再スキャン

local function load_modules_cache()
    local db = uep_db.get()
    if not db then return end

    local rows = db:eval([[
        SELECT name, root_path FROM modules 
        ORDER BY length(root_path) DESC
    ]])
    
    if not rows then 
        cached_modules = {}
        return 
    end

    cached_modules = {}
    for _, row in ipairs(rows) do
        table.insert(cached_modules, {
            name = row.name,
            root_path = unl_path.normalize(row.root_path):lower()
        })
    end
end

local function get_module_from_path(file_path)
    if not cached_modules then
        load_modules_cache()
    end
    
    if not cached_modules then return nil end

    -- 正規化 (呼び出し元で既に正規化されている前提だが念のため確認、あるいは呼び出し元に任せる)
    -- ここでは file_path は既に normalized & lower と仮定したいが、安全のためにはチェック
    -- 最適化: 呼び出し元が on_change なら正規化済み
    
    for _, row in ipairs(cached_modules) do
        if file_path:find(row.root_path, 1, true) then
            return row.name
        end
    end
    
    return nil
end

local function on_change(err, filename, events, watched_dir)
    if err then
        -- Error logging is important, keep it but maybe limit rate?
        uep_log.get().error("Watcher error: %s", tostring(err))
        return
    end
    
    if not filename then return end

    -- Optimize: simple string check before any normalization or heavy logic
    local lower_filename = filename:lower()
    
    -- Filter common build directories
    if lower_filename:find("intermediate", 1, true) or lower_filename:find("binaries", 1, true) then
        if lower_filename:match("[\\/]intermediate[\\/]") or lower_filename:match("[\\/]binaries[\\/]") then return end
        if lower_filename:match("^intermediate[\\/]") or lower_filename:match("^binaries[\\/]") then return end
    end
    
    -- Filter ignored extensions and dotfiles
    local ext = vim.fn.fnamemodify(filename, ":e"):lower()
    if ext == "tmp" or ext == "log" or ext == "txt" then return end
    if filename:match("^%.") then return end

    -- Construct full path
    local full_path = unl_path.normalize(fs.joinpath(watched_dir, filename))

    -- Additional robust directory check
    if full_path:find("/Intermediate/", 1, true) or full_path:find("/Binaries/", 1, true) then
        return
    end

    -- Throttling: Ignore events for the same file within THROTTLE_MS
    local now = vim.loop.now()
    local last_time = last_event_times[full_path]
    if last_time and (now - last_time < THROTTLE_MS) then
        -- Too frequent, ignore
        return
    end
    last_event_times[full_path] = now

    -- Normalize for module lookup
    local normalized_path_for_lookup = full_path:lower()

    -- Excessive logging causes lag. Removed debug/trace logs from hot path.
    -- uep_log.get().debug("File changed: %s", full_path)

    local module_name = get_module_from_path(normalized_path_for_lookup)
    if module_name then
        -- 変更ファイルを記録
        if not pending_changes[module_name] then pending_changes[module_name] = {} end
        pending_changes[module_name][full_path] = true
        
        -- Timer Reuse Logic
        local timer = debounce_timers[module_name]
        
        if not timer or timer:is_closing() then
            timer = vim.loop.new_timer()
            debounce_timers[module_name] = timer
        end
        
        timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
            if processing_modules[module_name] then
                -- uep_log.get().debug("Module update already in progress: %s", module_name)
                return
            end
            
            processing_modules[module_name] = true
            
            -- changed files listを取得してクリア
            local changes_map = pending_changes[module_name] or {}
            pending_changes[module_name] = nil
            
            local changed_files = vim.tbl_keys(changes_map)
            local change_count = #changed_files
            
            if change_count == 0 then
               processing_modules[module_name] = nil
               return
            end
            
            if change_count <= BULK_UPDATE_THRESHOLD then
                 uep_log.get().info("Auto-refreshing %d file(s) in module: %s", change_count, module_name)
                 
                 local completed = 0
                 for _, fpath in ipairs(changed_files) do
                     refresh_modules.update_single_file_cache(module_name, fpath, function(ok)
                         completed = completed + 1
                         if completed >= change_count then
                             processing_modules[module_name] = nil
                             uep_log.get().info("Auto-refresh (single-file mode) completed for module: %s", module_name)
                         end
                     end)
                 end
            else
                 uep_log.get().info("Auto-refreshing module (bulk mode): %s (%d files changed)", module_name, change_count)
                 refresh_modules.update_single_module_cache(module_name, function(ok) 
                     processing_modules[module_name] = nil
                     if ok then
                         uep_log.get().info("Auto-refresh (bulk mode) completed for: %s", module_name)
                     else
                         uep_log.get().error("Auto-refresh failed for: %s", module_name)
                     end
                 end)
            end
        end))
    else
        -- uep_log.get().trace("Unknown module file: %s", full_path)
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

    -- Cache modules upfront
    load_modules_cache()
    
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
    cached_modules = nil -- Clear cache
    last_event_times = {} -- Clear throttle table
    uep_log.get().info("UEP watcher stopped.")
end

function M.is_running()
    return #watcher_handles > 0
end

return M
