-- lua/UEP/cmd/start.lua
local uep_log = require("UEP.logger")
local uep_watcher = require("UEP.watcher")
local uep_db = require("UEP.db.init")
local uep_config = require("UEP.config")
local cmd_refresh = require("UEP.cmd.refresh")
local uep_vcs = require("UEP.vcs.init")

local M = {}

M.run = function(opts)
  if uep_watcher.is_running() then
    uep_log.get().warn("UEP watcher is already running.")
    return
  end

  local config = uep_config.get()
  if config.server and config.server.enable then
    local server_name = config.server.name
    if vim.fn.has('win32') == 1 then
      if not server_name:match("^\\\\%.\\pipe\\") then
        server_name = [[\\.\pipe\]] .. server_name
      end
    end

    local ok, _ = pcall(vim.fn.serverstart, server_name)
    if ok then
      uep_log.get().info("UEP Server started at: " .. server_name)
    else
      uep_log.get().warn("Failed to start UEP Server at: " .. server_name)
    end
  end
  
  -- DBアクセスのために初期化 (テーブル作成など)
  local db = uep_db.get()
  if not db then
    uep_log.get().error("Failed to initialize UEP database.")
    return
  end

  local root_path = vim.loop.cwd()
  local stored_rev = uep_db.get_meta("vcs_revision")

  uep_log.get().info("Checking VCS status for auto-refresh...")

  -- 現在のVCSリビジョンを取得
  uep_vcs.get_revision(root_path, function(current_rev, vcs_type)
    local need_refresh = false
    local reason = ""

    if current_rev then
      -- VCSが検出された場合
      if current_rev ~= stored_rev then
        need_refresh = true
        if not stored_rev then
          reason = "Initial setup (VCS detected)"
        else
          reason = string.format("Revision changed (%s -> %s)", tostring(stored_rev):sub(1,8), tostring(current_rev):sub(1,8))
        end
      else
        uep_log.get().info("VCS revision matches. Skipping refresh.")
      end
    else
      -- VCSが検出されなかった場合 (または取得失敗)
      if not stored_rev then
        -- DBに記録もなく、VCSもない -> 初回起動とみなす
        need_refresh = true
        reason = "Initial setup (No VCS)"
      else
        -- 以前はVCSがあったかもしれないが、今は取得できない、またはVCS管理外
        -- DBがあるなら、とりあえずWatcherを開始するだけでも良い
        uep_log.get().warn("VCS revision not found, but DB exists. Proceeding with watcher.")
      end
    end

    if need_refresh then
      uep_log.get().info("Starting Full Refresh... Reason: %s", reason)
      
      cmd_refresh.execute({ scope = "Full" }, function(success)
        if success then
          -- リフレッシュ成功時のみリビジョンを保存
          if current_rev then
            uep_db.set_meta("vcs_revision", current_rev)
          end
          uep_log.get().info("Refresh completed. Starting watcher...")
          uep_watcher.start()
        else
          uep_log.get().error("Initial refresh failed. Watcher NOT started.")
        end
      end)
    else
      uep_log.get().info("Starting watcher...")
      uep_watcher.start()
    end
  end)
end

return M
