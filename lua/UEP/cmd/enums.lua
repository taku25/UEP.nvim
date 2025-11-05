-- lua/UEP/cmd/enums.lua
-- (新規作成)

local core_find_symbol = require("UEP.cmd.core.find_symbol")
local uep_log = require("UEP.logger")

local M = {}

--- コマンドのエントリーポイント
-- @param opts table コマンドビルダーから渡される引数 ({ scope = "...", deps_flag = "..." })
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 1. スコープをパース (デフォルト: runtime)
  local requested_scope = "runtime"
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }
  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          log.warn("Invalid scope argument '%s' for enums command. Defaulting to 'runtime'.", opts.scope)
      end
  end

  -- 2. Depsフラグをパース (デフォルト: --deep-deps)
  local requested_deps = "--deep-deps"
  local valid_deps = { ["--deep-deps"]=true, ["--shallow-deps"]=true, ["--no-deps"]=true }
  if opts.deps_flag then
      local deps_lower = opts.deps_flag:lower()
      if valid_deps[deps_lower] then
          requested_deps = deps_lower
      else
          log.warn("Invalid deps flag '%s' for enums command. Defaulting to '--deep-deps'.", opts.deps_flag)
      end
  end

  log.debug("Executing :UEP enums with scope=%s, deps_flag=%s, bang=%s",
            requested_scope, requested_deps, tostring(opts.has_bang))

  -- ▼▼▼ [変更] symbol_type を "enum" に変更 ▼▼▼
  core_find_symbol.find_and_jump({
    symbol_type = "enum",
    has_bang = opts.has_bang,
    scope = requested_scope,
    deps_flag = requested_deps,
  })
  -- ▲▲▲ 変更完了 ▲▲▲
end

return M
