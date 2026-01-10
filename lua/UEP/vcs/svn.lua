-- lua/UEP/vcs/svn.lua
local M = {}

local function spawn_svn(args, cwd, on_success)
  if vim.fn.executable("svnversion") == 0 then
    on_success(nil)
    return
  end

  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local output_data = ""

  local handle, pid
  handle, pid = vim.loop.spawn("svnversion", {
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
function M.get_revision(root_path, on_complete)
  if not root_path then 
    on_complete(nil) 
    return 
  end

  -- Check for .svn directory to avoid unnecessary process spawning
  local svn_dir = vim.fs.find(".svn", { path = root_path, upward = true, stop = vim.loop.os_homedir() })
  if #svn_dir == 0 then
    on_complete(nil)
    return
  end

  -- svnversion returns the state of the working copy (e.g., "1234", "1234M", "1234:1235")
  spawn_svn({ "." }, root_path, function(output)
    if output then
        local rev = output:gsub("%s+", "")
        -- "Unversioned directory" or empty means failed
        if rev ~= "" and not rev:match("Unversioned") then
            on_complete(rev)
            return
        end
    end
    on_complete(nil)
  end)
end

return M
