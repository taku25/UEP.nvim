-- lua/UEP/vcs/git.lua
local M = {}

local function spawn_git(args, cwd, on_success)
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local output_data = ""

  local handle, pid
  handle, pid = vim.loop.spawn("git", {
    args = args,
    cwd = cwd,
    stdio = { nil, stdout, stderr }
  }, function(code, signal)
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    handle:close()

    vim.schedule(function()
      if code == 0 then
        on_success(output_data)
      else
        on_success(nil) 
      end
    end)
  end)

  if handle then
    vim.loop.read_start(stdout, function(err, data)
      if data then output_data = output_data .. data end
    end)
    vim.loop.read_start(stderr, function(err, data) end)
  else
    vim.schedule(function() on_success(nil) end)
  end
end

-- 現在のリビジョンを取得する
-- (HEADハッシュ + サブモジュールの状態ハッシュ)
function M.get_revision(root_path, on_complete)
  if not root_path then 
    on_complete(nil) 
    return 
  end

  -- Check if .git exists
  local git_dir = vim.fs.find(".git", { path = root_path, upward = true, stop = vim.loop.os_homedir() })
  if #git_dir == 0 then
    on_complete(nil)
    return
  end

  -- 1. Get HEAD revision
  spawn_git({"rev-parse", "HEAD"}, root_path, function(head_rev)
    if not head_rev then
      on_complete(nil)
      return
    end
    head_rev = head_rev:gsub("%s+", "") -- Trim

    -- 2. Get Submodules status
    spawn_git({"submodule", "status", "--recursive"}, root_path, function(sub_status)
      local combined = head_rev
      if sub_status and sub_status ~= "" then
        combined = combined .. "\n" .. sub_status
      end
      
      -- Generate hash of the combined state using sha256
      local hash = vim.fn.sha256(combined)
      on_complete(hash)
    end)
  end)
end

return M
