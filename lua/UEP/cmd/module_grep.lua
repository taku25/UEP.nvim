-- lua/UEP/cmd/module_grep.lua
-- :UEP grep_module コマンドの実装（初期クエリなしバージョン）
local grep_core = require("UEP.cmd.grep_core")
local uep_log = require("UEP.logger")
local project_cache = require("UEP.cache.project")
local unl_finder = require("UNL.finder")
local unl_picker = require("UNL.backend.picker") -- モジュール選択用に必要
local uep_config = require("UEP.config") -- モジュール選択用に必要

local M = {}

---
-- 指定されたモジュール名でLive Grepを開始する内部関数
-- @param module_name string 検索対象のモジュール名
local function start_grep_for_module(module_name)
  local log = uep_log.get()

  -- モジュール情報から検索範囲 (search_paths) を特定
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    return log.error("Not in an Unreal Engine project directory.")
  end

  local game_data = project_cache.load(project_root)
  if not game_data then
    return log.error("Project cache not found. Run :UEP refresh first.")
  end

  -- GameとEngineの両方のモジュール情報をマージして探す
  local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil
  local all_modules = vim.tbl_deep_extend("force", engine_data and engine_data.modules or {}, game_data.modules or {})
  local target_module_info = all_modules[module_name]

  if not (target_module_info and target_module_info.module_root) then
    return log.error("Module '%s' not found in cache.", module_name)
  end

  -- grep_core を呼び出してピッカーを起動（初期クエリは空）
  grep_core.start_live_grep({
    search_paths = { target_module_info.module_root },
    title = string.format("Live Grep (in %s)", module_name),
    initial_query = "",
  })
end

---
-- コマンドビルダーから呼び出される実行関数
-- @param opts table | nil コマンド引数を含むテーブル
function M.execute(opts)
  opts = opts or {}

  if opts.module_name then
    -- 引数でモジュール名が指定されていれば、すぐにGrepを開始
    start_grep_for_module(opts.module_name)
  else
    -- モジュール名がなければ、ピッカーで選択させる
    local log = uep_log.get()
    local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
    if not project_root then
      return log.error("Not in an Unreal Engine project directory.")
    end

    local game_data = project_cache.load(project_root)
    if not game_data then
      return log.error("Project cache not found. Run :UEP refresh first.")
    end

    local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil
    local all_modules = vim.tbl_deep_extend("force", engine_data and engine_data.modules or {}, game_data.modules or {})

    local picker_items = {}
    for name, meta in pairs(all_modules) do
      table.insert(picker_items, { label = string.format("%s (%s)", name, meta.category), value = name })
    end
    table.sort(picker_items, function(a, b) return a.value < b.value end)

    unl_picker.pick({
      kind = "uep_select_module_for_grep",
      title = "Select a Module to Search",
      items = picker_items,
      conf = uep_config.get(),
      on_submit = function(selected_module_name)
        if selected_module_name then
          -- ユーザーがモジュールを選択したら、そのモジュールでGrepを開始
          start_grep_for_module(selected_module_name)
        end
      end,
    })
  end
end

return M
