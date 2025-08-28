-- lua/UEP/cmd/module_tree.lua
-- :UEP module_tree コマンド。単一モジュールのツリービューを表示する。
-- 引数がない場合は、ピッカーでモジュールを選択させます。

local tree_model_controller = require("UEP.core.tree_model_controller")
local tree_model_context = require("UEP.state.tree_model_context")
local unl_finder = require("UNL.finder")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local uep_log      = require("UEP.logger")
-- ★★★ 必要なモジュールを追加 ★★★
local project_cache = require("UEP.cache.project")
local unl_picker = require("UNL.backend.picker")
local uep_config   = require("UEP.config")
local uep_event_hub = require("UEP.event.hub")

local M = {}

---
-- 指定された単一モジュールのツリービューを表示するためのメインロジック
-- @param module_name string 表示したいモジュールの名前
local function show_tree_for_module(module_name, all_modules_cache)
  if not module_name then return end -- ユーザーがピッカーをキャンセルした場合など

  local project_root = unl_finder.project.find_project_root(vim.fn.getcwd())
  if not project_root then
    uep_log.get().error("Not in an Unreal Engine project directory.")
    return
  end

  uep_log.get().info("Requesting tree view for single module: %s", module_name)

  -- 1. 最後に使われた引数として、モジュール名を含むコンテキストを保存
  local args = {
    module_name = module_name,
    view_type = "module",
    all_modules = all_modules_cache, -- 計算結果を渡す
  }
  tree_model_context.set_last_args(args)

  -- 2. コントローラーを呼び出して、単一モジュール用のモデルを構築
  local ok, nodes = tree_model_controller.build(project_root, args)
  if ok then
    -- 3. モデル更新イベントを発行
    uep_event_hub.request_tree_update(nodes)
    
    -- 4. neo-treeを開く/フォーカスする
    local ok_api, neo_tree_cmd = pcall(require, "neo-tree.command")
    if ok_api then
      neo_tree_cmd.execute({ source = "uproject", action = "focus" })
    end
  end
end

---
-- コマンドのメインエントリーポイント
function M.execute(opts)
  if opts and opts.module_name then
    -- =======================================================
    -- CASE 1: コマンドでモジュール名が直接指定された場合
    -- 例: :UEP module_tree MyGameModule
    -- =======================================================
    show_tree_for_module(opts.module_name)
  else
    -- =============================================
    -- CASE 2: モジュール名が指定されなかった場合
    -- -> ピッカーでユーザーに選択させる
    -- =============================================
    uep_log.get().info("Module name not provided, showing picker...")
    
    -- 1. GameとEngineの全モジュール情報をキャッシュから集約
    local game_data = project_cache.load(vim.loop.cwd())
    if not game_data then return end
    local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil
    local all_modules = {}
    if game_data and game_data.modules then
      for name, meta in pairs(game_data.modules) do all_modules[name] = meta end
    end
    if engine_data and engine_data.modules then
      for name, meta in pairs(engine_data.modules) do
        if not all_modules[name] then all_modules[name] = meta end
      end
    end

    if not next(all_modules) then
      uep_log.get().warn("No modules found in cache. Run ':UEP refresh' first.")
      return
    end
    local picker_items = {}
    for name, meta in pairs(all_modules) do
      table.insert(picker_items, { label = string.format("%s (%s)", name, meta.category), value = name })
    end
    table.sort(picker_items, function(a, b) return a.value < b.value end)
    
    unl_picker.pick({
      kind = "module_select_for_refresh", 
      title = "Select a Module to REFRESH files",
      items = picker_items,
      format = function(item) return item.label end,
      preview_enabled = false,

      conf = uep_config.get(),
      on_submit = function(selected_module_name)
        if selected_module_name then
          show_tree_for_module(selected_module_name, all_modules)
        end
      end,
      config_name = uep_config.name,
      logger_name = uep_log.name,
    })

  end
end

return M
