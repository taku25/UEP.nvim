-- lua/UEP/cmd/module_tree.lua (新Depsフラグ対応版)
-- [!] tree provider を呼び出して展開状態をクリアするよう修正

local uep_log = require("UEP.logger").get()
local unl_finder = require("UNL.finder")
local unl_context = require("UNL.context")
local uep_db = require("UEP.db.init")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local cmd_tree_provider = require("UEP.provider.tree") -- [! 1. provider を require]
local ui_control = require("UEP.cmd.core.ui_control") -- ★ 追記

local M = {}


function M.execute(opts)
  opts = opts or {}
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return uep_log.error("Not in an Unreal Engine project.") end

  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject,
    { engine_override_path = uep_config.get().engine_path })

  -- ▼▼▼ 修正箇所: 新しい deps フラグをパース ▼▼▼
  local requested_deps = "--deep-deps" -- デフォルトは deep
  local valid_deps = { ["--deep-deps"]=true, ["--shallow-deps"]=true, ["--no-deps"]=true }
  if opts.deps_flag then
      local deps_lower = opts.deps_flag:lower()
      if valid_deps[deps_lower] then
          requested_deps = deps_lower
      else
          uep_log.warn("Invalid deps flag '%s'. Defaulting to '--deep-deps'. Valid flags: --deep-deps, --shallow-deps, --no-deps.", opts.deps_flag)
      end
  end

  local payload = {
    project_root = project_root,
    engine_root = engine_root,
    all_deps = (requested_deps == "--deep-deps"), -- 古い all_deps も一応設定しておく
    scope = nil, -- module_tree では scope は使わない
    deps_flag = requested_deps, -- ★ 新しい deps フラグ
    target_module = opts.module_name, -- 指定されていれば設定
  }
  -- ▲▲▲ 修正ここまで ▲▲▲

  if payload.target_module then
    -- モジュール名が指定されていれば、すぐにリクエストを保存して neo-tree を開く
    ui_control.handle_tree_request(payload)
  else
    -- モジュール名が指定されていなければ、ピッカーで選択させる
    uep_log.info("Fetching module list for picker...")

    -- ▼▼▼ モジュールリスト取得ロジック修正 (DB) ▼▼▼
    local db = uep_db.get()
    if not db then return uep_log.error("DB not available") end

    local rows = db:eval("SELECT name, owner_name FROM modules")
    if not rows or #rows == 0 then
        return uep_log.error("Module list fetch failed: No modules found in DB.")
    end

    local all_modules_picker = {}
    for _, row in ipairs(rows) do
        local owner_display = row.owner_name or "Unknown"
        table.insert(all_modules_picker, {
            label = string.format("%s (%s)", row.name, owner_display),
            value = row.name
        })
    end
    table.sort(all_modules_picker, function(a, b) return a.label < b.label end)
    -- ▲▲▲ モジュールリスト取得ロジック修正ここまで ▲▲▲

    unl_picker.pick({
      kind = "uep_select_module_for_tree",
      title = "Select Module to Display",
      items = all_modules_picker, -- ★ 修正したリストを使用
      conf = uep_config.get(),
      preview_enabled = false, -- モジュール選択なのでプレビュー不要
      devicons_enabled = false, -- 同上
      on_submit = function(selected_module)
        if not selected_module then return end
        payload.target_module = selected_module
        ui_control.handle_tree_request(payload)
      end,
    })
  end
end

return M
