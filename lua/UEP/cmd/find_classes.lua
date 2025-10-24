-- lua/UEP/cmd/classes.lua

-- コアロジックを require
local core_find_symbol = require("UEP.cmd.core.find_symbol")

local M = {}

--- コマンドのエントリーポイント
-- @param opts table コマンドビルダーから渡される引数 ({ class_name = "..." })
-- lua/UEP/cmd/classes.lua (引数指定削除版)
function M.execute(opts)
  opts = opts or {}
  -- [!] :UEP files と同じ引数パースロジック (Scope, DepsFlag のみ)
  local scope = opts.category or "Game"
  local deps_flag = opts.deps_flag or "--no-deps"
  print(deps_flag)

  core_find_symbol.find_and_jump({
    symbol_type = "class",
    has_bang = opts.has_bang,
    scope = scope,
    deps_flag = deps_flag,
  })
end

return M
