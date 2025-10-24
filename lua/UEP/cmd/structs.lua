-- lua/UEP/cmd/structs.lua

-- コアロジックを require
local core_find_symbol = require("UEP.cmd.core.find_symbol")

local M = {}

--- コマンドのエントリーポイント
-- @param opts table コマンドビルダーから渡される引数 ({ struct_name = "..." })
function M.execute(opts)
  opts = opts or {}
  -- [!] :UEP files と同じ引数パースロジック (Scope, DepsFlag のみ)
  local scope = opts.category or "Game"
  local deps_flag = opts.deps_flag or "--no-deps"

  core_find_symbol.find_and_jump({
    symbol_type = "struct",
    has_bang = opts.has_bang,
    scope = scope,
    deps_flag = deps_flag,
  })
end

return M
