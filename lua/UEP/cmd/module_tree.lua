-- lua/UEP/cmd/module_tree.lua (プロバイダーアーキテクチャ版)

local uep_log = require("UEP.logger").get()
local unl_finder = require("UNL.finder")
local unl_context = require("UNL.context")
local project_cache = require("UEP.cache.project")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")

local M = {}

-- 実際にリクエストを保存してneo-treeを開く共通関数
local function store_request_and_open_neotree(payload)

  unl_events.publish(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, payload )
  unl_context.use("UEP"):key("pending_request:neo-tree-uproject"):set("payload", payload)
  uep_log.info("A request to view a module tree has been stored for neo-tree.")

  local ok, neo_tree_cmd = pcall(require, "neo-tree.command")
  if ok then
    neo_tree_cmd.execute({ source = "uproject", action = "focus" })
  end
end

function M.execute(opts)
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return end
  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject, {})
  
  -- 基本となるリクエスト情報を作成
  local payload = {
    project_root = project_root,
    engine_root = engine_root,
    all_deps = (opts.deps_flag == "--all-deps"),
  }

  -- コマンド引数でモジュール名が指定されていれば、それをpayloadに追加して実行
  if opts.module_name then
    payload.target_module = opts.module_name
    store_request_and_open_neotree(payload)
  else
    -- モジュール名がなければ、Pickerで選択させる
    local game_data = project_cache.load(vim.loop.cwd())
    if not game_data then return end
    local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil
    
    local all_modules = vim.tbl_deep_extend("force", engine_data and engine_data.modules or {}, game_data.modules or {})
    
    local picker_items = {}
    for name, meta in pairs(all_modules) do
      table.insert(picker_items, { label = string.format("%s (%s)", name, meta.category), value = name })
    end
    table.sort(picker_items, function(a, b) return a.value < b.value end)
    
    unl_picker.pick({
      kind = "uep_select_module_for_tree",
      title = "Select Module to Display",
      items = picker_items,
      conf = uep_config.get(),
      on_submit = function(selected_module)
        if not selected_module then return end
        payload.target_module = selected_module
        store_request_and_open_neotree(payload)
      end,
    })
  end
end

return M
