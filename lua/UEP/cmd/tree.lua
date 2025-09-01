-- lua/UEP/cmd/tree.lua
-- :UEP tree コマンドの実処理 (イベント発行モデル)
-- 責務: 1. 引数を解釈し, 2. キャッシュからデータを構築し, 3. グローバルイベントを発行する

local unl_finder = require("UNL.finder")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local tree_model_context = require("UEP.state.tree_model_context")
local tree_model_controller = require("UEP.core.tree_model_controller")
local uep_event_hub = require("UEP.event.hub")
  local uep_log           = require("UEP.logger")

local uep_config   = require("UEP.config")
local M = {}

---
-- キャッシュからノードを構築するヘルパー関数
-- (この関数はコマンド間で共通化して別ファイルに切り出すのが理想的)
--
function M.execute(opts)
  -- ★★★ 最初に、UIの存在をチェックする ★★★
  local ok_neotree, _ = pcall(require, "neo-tree.command")
  -- local ok_unl_source, _ = pcall(require, "neo-tree-unl")
  if not (ok_neotree) then
    uep_log.get().warn("Optional UI plugins ('neo-tree.nvim', 'neo-tree-unl.nvim') are not available.")
    return
  end
  
  -- (これ以降は、UIが存在することが保証されている)
  tree_model_context.set_last_args(opts)
  local project_root = unl_finder.project.find_project_root(vim.fn.getcwd())
  if not project_root then return end
  
  local ok, nodes_to_render = tree_model_controller.build(project_root, opts)
  if ok then
    require("UEP.event.hub").request_tree_update(nodes_to_render)
    require("neo-tree.command").execute({ source = "uproject", action = "focus" })
  end
end

return M
