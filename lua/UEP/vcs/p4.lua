-- lua/UEP/vcs/p4.lua
local M = {}

local function spawn_p4(args, cwd, on_success)
  if vim.fn.executable("p4") == 0 then
    on_success(nil)
    return
  end

  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local output_data = ""

  local handle, pid
  handle, pid = vim.loop.spawn("p4", {
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

-- 現在のリビジョン(Changeset)を取得する
function M.get_revision(root_path, on_complete)
  if not root_path then 
    on_complete(nil) 
    return 
  end

  -- P4 environment check is complex (P4PORT, P4CLIENT vars etc), so we rely on the command execution result.
  -- "changes -m1 ...#have" returns the highest changelist number synced in this path.
  spawn_p4({ "changes", "-m1", "...#have" }, root_path, function(output)
    if output then
        -- Output example: "Change 123456 on 2025/01/10 by user@client '...'"
        local rev = output:match("Change (%d+)")
        if rev then
            on_complete(rev)
            return
        end
    end
    on_complete(nil)
  end)
end

return M
