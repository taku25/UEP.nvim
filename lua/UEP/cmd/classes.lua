-- lua/UEP/cmd/classes.lua (新スコープ・Depsフラグ対応版)

local core_find_symbol = require("UEP.cmd.core.find_symbol")
local uep_log = require("UEP.logger") -- ★ ログ用に追加

local M = {}

--- コマンドのエントリーポイント
-- @param opts table コマンドビルダーから渡される引数 ({ scope = "...", deps_flag = "..." })
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get() -- ★ ログ取得

  -- ▼▼▼ 引数パース処理を修正 ▼▼▼
  -- 1. スコープをパース (デフォルト: runtime)
  local requested_scope = "runtime"
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }
  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          log.warn("Invalid scope argument '%s' for classes command. Defaulting to 'runtime'.", opts.scope)
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
          log.warn("Invalid deps flag '%s' for classes command. Defaulting to '--deep-deps'.", opts.deps_flag)
      end
  end
  -- ▲▲▲ 引数パース修正ここまで ▲▲▲

  log.debug("Executing :UEP classes with scope=%s, deps_flag=%s, bang=%s",
            requested_scope, requested_deps, tostring(opts.has_bang))

  -- ▼▼▼ core_find_symbol.find_and_jump にパース結果を渡す ▼▼▼
  core_find_symbol.find_and_jump({
    symbol_type = "class",
    has_bang = opts.has_bang,
    scope = requested_scope,     -- ★ パースしたスコープ
    deps_flag = requested_deps, -- ★ パースしたDepsフラグ
  })
  -- ▲▲▲ 呼び出し修正ここまで ▲▲▲
end

return M
