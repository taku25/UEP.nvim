-- lua/UEP/cmd/tree.lua (新スコープ完全対応版)
-- [!] tree provider を呼び出して展開状態をクリアするよう修正

local uep_log = require("UEP.logger").get()
local unl_finder = require("UNL.finder")
local unl_context = require("UNL.context")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local uep_config = require("UEP.config")
local cmd_tree_provider = require("UEP.provider.tree") -- [! 1. provider を require]

local M = {}

function M.execute(opts)
  opts = opts or {}
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return uep_log.error("Not in an Unreal Engine project.") end

  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject,
    { engine_override_path = uep_config.get().engine_path })

  -- ▼▼▼ 修正箇所: 新しいスコープ引数をパース ▼▼▼
  local requested_scope = "runtime" -- デフォルトは runtime
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }

  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          uep_log.warn("Invalid scope argument '%s'. Defaulting to 'runtime'. Valid scopes are: Game, Engine, Runtime, Developer, Editor, Full.", opts.scope)
          -- requested_scope はデフォルトの "runtime" のまま
      end
  end

  -- 新しい deps フラグのパース (デフォルトは --deep-deps)
  local requested_deps = "--deep-deps"
  local valid_deps = { ["--deep-deps"]=true, ["--shallow-deps"]=true, ["--no-deps"]=true }
  if opts.deps_flag then
      local deps_lower = opts.deps_flag:lower()
      if valid_deps[deps_lower] then
          requested_deps = deps_lower
      else
          uep_log.warn("Invalid deps flag '%s'. Defaulting to '--deep-deps'. Valid flags are: --deep-deps, --shallow-deps, --no-deps.", opts.deps_flag)
      end
  end


  local payload = {
    project_root = project_root,
    engine_root = engine_root,
    all_deps = (requested_deps == "--deep-deps"), -- all_deps は deep と同義とするか？ provider側で調整
    target_module = nil,
    scope = requested_scope,     -- ★ 新しいスコープ名
    deps_flag = requested_deps, -- ★ 新しい deps フラグ
  }
  -- ▲▲▲ 修正ここまで ▲▲▲

  -- [! 2. ツリーを開く前に、展開状態キャッシュをクリアする]
  cmd_tree_provider.request({ capability = "uep.clear_tree_state" })
  uep_log.debug("Cleared tree expanded state for new :UEP tree request.")

  unl_context.use("UEP"):key("pending_request:" .. "neo-tree-uproject"):set("payload", payload)
  uep_log.info("Request stored for neo-tree. Scope: %s, Deps: %s", requested_scope, requested_deps)

  unl_events.publish(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, payload )

  local ok, neo_tree_cmd = pcall(require, "neo-tree.command")
  if ok then
    neo_tree_cmd.execute({ source = "uproject", action = "focus" })
  else
    uep_log.warn("neo-tree command not found.")
  end

end

return M
