-- lua/UEP/cmd/refresh.lua (Rust Scanner Integrated Version)

local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local uep_db = require("UEP.db.init")
local projects_cache = require("UEP.cache.projects")
local uep_vcs = require("UEP.vcs.init")
local unl_progress = require("UNL.backend.progress")
local unl_finder = require("UNL.finder")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")

local M = {}

function M.execute(opts, on_complete)
  opts = opts or {}
  local log = uep_log.get()
  
  -- 1. スキャナバイナリの取得
  local unl_scanner_ok, unl_scanner = pcall(require, "UNL.scanner")
  if not unl_scanner_ok or not unl_scanner.has_binary() then
    log.error("UNL Scanner binary not found. Please build UNL.nvim scanner.")
    if unl_scanner_ok then unl_scanner.warn_binary_missing() end
    if on_complete then on_complete(false) end
    return
  end
  local binary_path = unl_scanner.get_binary_path()

  -- 2. プロジェクト情報の取得
  local project_info = unl_finder.project.find_project(vim.loop.cwd())
  if not (project_info and project_info.uproject) then
    log.error("Could not find a .uproject file.")
    if on_complete then on_complete(false) end
    return
  end
  local uproject_path = project_info.uproject
  local game_root = vim.fn.fnamemodify(uproject_path, ":h")

  local conf = uep_config.get()
  local engine_root = unl_finder.engine.find_engine_root(uproject_path, {
    engine_override_path = conf.engine_path,
  })

  if not engine_root or engine_root == "" or vim.fn.isdirectory(engine_root) == 0 then
    log.error("Could not find a valid Unreal Engine root.")
    if on_complete then on_complete(false) end
    return
  end

  local db_path = uep_db.get_path()
  if not db_path then
    log.error("Failed to determine DB path.")
    if on_complete then on_complete(false) end
    return
  end

  -- 3. RefreshRequest JSONの構築
  -- Rust Scanner側のパス区切り対応のため正規化
  local function norm(p) return p:gsub("\\", "/") end
  
  -- スコープの決定 (デフォルトは "Game" - 高速化のため)
  -- 1. DBが存在しない場合は強制的に "Full" (初回構築のため)
  -- 2. forceフラグやbang(!)がある場合は "Full"
  local scope = opts.scope or "Game"
  local db_exists = vim.fn.filereadable(db_path) == 1
  
  if not db_exists then
    scope = "Full"
    log.info("DB not found at %s. Forcing Full refresh.", db_path)
  elseif opts.force or opts.has_bang then
    scope = "Full"
  end
  log.info("Refresh scope: %s", scope)

  local req = {
    type = "refresh",
    project_root = norm(game_root),
    engine_root = norm(engine_root),
    db_path = norm(db_path),
    scope = scope,
    config = {
      include_extensions = conf.include_extensions or {"uproject", "cpp", "h", "hpp", "inl", "ini", "cs"},
      excludes_directory = conf.excludes_directory or {"Intermediate", "Binaries", "Saved", ".git", ".vs", "Templates"},
    }
  }

  local json_file = vim.fn.tempname() .. ".json"
  local f = io.open(json_file, "w")
  if not f then
    log.error("Failed to write temporary config file.")
    if on_complete then on_complete(false) end
    return
  end
  f:write(vim.json.encode(req))
  f:close()

  -- 4. プログレスバー開始
  local progress, _ = unl_progress.create_for_refresh(conf, {
    title = "UEP: Refreshing project (Rust Scanner)...",
    client_name = "UEP",
    weights = {
      discovery = 0.1,
      db_sync = 0.1,
      file_scan = 0.1,
      analysis = 0.6,
      complete = 0.1,
    }
  })
  progress:open()
  
  -- [Fix] Aggregatorにステージを認識させるため、事前に定義しておく
  progress:stage_define("discovery", 100)
  progress:stage_define("db_sync", 100)
  progress:stage_define("file_scan", 10000) -- 仮の最大値
  progress:stage_define("analysis", 10000)  -- 仮の最大値
  progress:stage_define("complete", 100)

  -- [Fix] Watcherを停止し、DB接続を閉じる (ファイルロック回避)
  local uep_watcher = require("UEP.watcher")
  uep_watcher.stop()
  uep_db.close()
  collectgarbage() -- 強制GCでハンドル解放を促進

  -- 5. ジョブ実行
  local cmd = { binary_path, "refresh", json_file }
  log.debug("Starting refresh scanner with config: %s", json_file)
  
  local line_buffer = ""
  vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data) 
      if not data then return end
      
      for i, chunk in ipairs(data) do
        if i == 1 then
          line_buffer = line_buffer .. chunk
        else
          -- 前の行が完成したということ
          local line = line_buffer
          line_buffer = chunk
          
          if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and msg and msg.type == "progress" then
               -- 動的な最大値更新 (Rustからのtotalを反映)
               if msg.stage == "file_scan" or msg.stage == "analysis" then
                   if msg.total and msg.total > 0 then
                       progress:stage_define(msg.stage, msg.total)
                   end
               end
               progress:stage_update(msg.stage, msg.current, msg.message)
            end
          end
        end
      end
    end,
    on_stderr = function(_, data) 
       if data then
         for _, line in ipairs(data) do
           if line ~= "" then log.error("%s", line) end
         end
       end
    end,
    on_exit = function(_, code)
      -- 最後のバッファを処理 (改行がなくても処理する)
      if line_buffer ~= "" then
        local ok, msg = pcall(vim.json.decode, line_buffer)
        if ok and msg and msg.type == "progress" then
           progress:stage_update(msg.stage, msg.current, msg.message)
        end
      end

      os.remove(json_file)
      local success = (code == 0)
      
      if success then
        log.info("Refresh completed successfully.")
        
        -- プロジェクトキャッシュの更新
        local db = uep_db.get() 
        if db then
           -- DB情報を最新にするため閉じ直す
           uep_db.close()
           db = uep_db.get()
           
           if db then
             -- Rustが作成したcomponentsテーブルから情報を取得
             local components = db:eval("SELECT * FROM components")
             if components and #components > 0 then
               local registration_info = {
                  root_path = game_root,
                  uproject_path = uproject_path,
                  engine_root = engine_root,
               }
               -- components テーブルから取得したレコードをそのまま渡す
               projects_cache.register_project_with_components(registration_info, components)
               log.debug("Registered %d components to project cache.", #components)
             end
           end
        end

        -- VCSリビジョン保存
        uep_vcs.get_revision(game_root, function(rev) 
            if rev then uep_db.set_meta("vcs_revision", rev) end
            progress:finish(true)
            unl_events.publish(unl_types.ON_AFTER_REFRESH_COMPLETED, { status = "success" })
            
            -- Watcher再開
            uep_watcher.start()
            
            if on_complete then on_complete(true) end
        end)
      else
        log.error("Refresh failed with exit code: %d", code)
        progress:finish(false)
        unl_events.publish(unl_types.ON_AFTER_REFRESH_COMPLETED, { status = "failed" })
        
        -- 失敗時もWatcher再開 (必要であれば)
        uep_watcher.start()
        
        if on_complete then on_complete(false) end
      end
    end
  })
end

return M