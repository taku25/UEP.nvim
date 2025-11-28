-- lua/UEP/cmd/config_tree.lua
local ui_control = require("UEP.cmd.core.ui_control")
local uep_log = require("UEP.logger").get()

local M = {}

function M.execute(opts)
  opts = opts or {}
  
  -- スコープのパース
  local requested_scope = "runtime" 
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }

  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          uep_log.warn("Invalid scope argument '%s'. Defaulting to 'runtime'.", opts.scope)
      end
  end

  -- UNXへ送るペイロード
  local payload = {
    scope = requested_scope,
    -- 将来的にここでフィルタリング条件などを追加可能
  }

  -- UI制御へリクエスト (UNXのConfigタブが開く)
  ui_control.handle_tree_request(payload)
end

return M
