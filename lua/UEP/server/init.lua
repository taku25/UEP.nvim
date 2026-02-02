local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_scanner = require("UNL.scanner")

local M = {}

local server_job_id = nil

function M.start()
  if server_job_id then
    uep_log.get().debug("Server is already running (job_id: %d)", server_job_id)
    return
  end

  local conf = uep_config.get().server
  if not conf.enable then return end

  local binary = unl_scanner.get_binary_path()
  if not binary then return end
  
  -- unl-server バイナリのパスを構築 (unl-scanner と同じ階層にある想定)
  local server_binary = binary:gsub("unl%-scanner", "unl-server")
  if vim.fn.executable(server_binary) == 0 then
    -- もし unl-server が見つからなければ scanner を server モードにするなどの将来設計もあり得るが、
    -- 今は作成した server_main バイナリを直接探す
    uep_log.get().warn("unl-server binary not found at: %s", server_binary)
    return
  end

  local cmd = { server_binary, tostring(conf.port) }
  uep_log.get().info("Starting UNL Server on port %d...", conf.port)

  server_job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then uep_log.get().debug("[Server] %s", line) end end end
    end,
    on_stderr = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then uep_log.get().error("[Server Error] %s", line) end end end
    end,
    on_exit = function(_, code)
      uep_log.get().info("UNL Server stopped with code: %d", code)
      server_job_id = nil
    end,
  })
end

function M.stop()
  if server_job_id then
    vim.fn.jobstop(server_job_id)
    server_job_id = nil
  end
end

function M.get_status(callback)
  local conf = uep_config.get().server
  local uv = vim.loop
  local client = uv.new_tcp()
  
  client:connect("127.0.0.1", conf.port, function(err)
    client:close()
    if err then
      if callback then callback(nil) end
    else
      -- 接続できた = サーバーは生きている
      if callback then callback({ status = "running", port = conf.port }) end
    end
  end)
end

return M
