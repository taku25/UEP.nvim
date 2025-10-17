-- lua/UEP/cmd/tree.lua (プロバイダーアーキテクチャ版)

local uep_log = require("UEP.logger").get()
local unl_finder = require("UNL.finder")
local unl_context = require("UNL.context")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local uep_config = require("UEP.config")

local M = {}

function M.execute(opts)
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    return uep_log.error("Not in an Unreal Engine project.")
  end
  
  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject,
    {
      engine_override_path = uep_config.get().engine_path,
    })

  -- 1. neo-treeに渡したい"リクエスト情報"を作成する
  --    これには、具体的なファイルリストなどは含まれない。
  --    あくまで「どのプロジェクトを、どのオプションで表示したいか」という情報だけ。
  local payload = {
    project_root = project_root,
    engine_root = engine_root,
    all_deps = (opts.deps_flag == "--all-deps"), 
    target_module = nil, -- :UEP tree コマンドなので、特定のモジュールは指定しない
  }


  -- 2. このリクエスト情報を UNL.context に保存する
  --    キー名 "pending_request:neo-tree-uproject" は、
  --    neo-tree側がプロバイダーを呼び出すときに使う `consumer` 名と一致させる
  unl_context.use("UEP"):key("pending_request:neo-tree-uproject"):set("payload", payload)
  uep_log.info("A request to view the uproject tree has been stored for neo-tree.")

  unl_events.publish(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, payload )

  -- 3. neo-treeを開くか、フォーカスを当てる
  --    これにより、neo-treeのnavigate関数がトリガーされ、
  --    プロバイダー経由で上記のリクエスト情報が取得される
  local ok, neo_tree_cmd = pcall(require, "neo-tree.command")
  if ok then
    -- neo_tree_cmd.execute({ source = "uproject", action = "focus" })
    neo_tree_cmd.execute({ source = "uproject", action = "focus" })
  else
    uep_log.warn("neo-tree.command not available. Please open neo-tree manually.")
  end
    
end

return M
