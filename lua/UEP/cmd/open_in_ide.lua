local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")

local M = {}

M.execute = function(opts)
  opts = opts or {}
  local file = opts.file_path or vim.fn.expand("%:p")
  if file == "" then
    uep_log.get().warn("No file to open.")
    return
  end

  local line = opts.line or vim.fn.line(".")
  local config = uep_config.get()
  
  local cmd_template = config.ide and config.ide.open_command
  
  if not cmd_template or cmd_template == "" then
     uep_log.get().warn("No IDE command configured. Please check 'ide.open_command' in config.")
     return
  end
  
  -- プレースホルダーの置換
  -- {file} -> ファイルパス (ダブルクォートで囲むかはユーザーの定義次第だが、ここでは安全のためパスにスペースがある場合を考慮して手動でクォートするか、ユーザーに任せるか。
  -- 柔軟性を高めるため、ユーザーが定義文字列内でクォートすることを推奨し、ここではそのまま置換する。
  -- ただし、Windowsのパス区切り文字などは考慮が必要。
  
  -- シンプルな置換
  local cmd_str = cmd_template:gsub("{line}", tostring(line))
  cmd_str = cmd_str:gsub("{file}", file)
  
  uep_log.get().info("Opening in IDE: " .. cmd_str)
  
  -- WindowsでGUIアプリを起動する場合、cmd /c start "" ... を使うと非同期で綺麗に起動しやすいが、
  -- ユーザーが直接実行ファイルパスを指定している場合もあるので、jobstartでそのまま投げる。
  -- パスが通っていない場合は実行できないので注意。
  
  local job_cmd
  if vim.fn.has("win32") == 1 then
      -- cmd.exe経由で実行することで、パス解決やstartコマンドの利用を容易にする
      -- ただし、startを使うと引数のクォート処理が面倒になることがある。
      -- ここでは単純に文字列としてシェルに渡す。
      job_cmd = {"cmd.exe", "/c", cmd_str}
  else
      job_cmd = {"sh", "-c", cmd_str}
  end

  vim.fn.jobstart(job_cmd, { 
    detach = true,
    on_exit = function(_, code)
      if code ~= 0 then
        uep_log.get().warn("IDE command failed with code: " .. code)
      end
    end
  })
end

return M
