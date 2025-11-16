-- lua/UEP/cmd/module_tree.lua (新Depsフラグ対応版)
-- [!] tree provider を呼び出して展開状態をクリアするよう修正

local uep_log = require("UEP.logger").get()
local unl_finder = require("UNL.finder")
local unl_context = require("UNL.context")
local project_cache = require("UEP.cache.project") -- ★ project_cache を使うように戻す
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local projects_cache = require("UEP.cache.projects") -- ★ projects_cache を追加
local cmd_tree_provider = require("UEP.provider.tree") -- [! 1. provider を require]

local M = {}

-- (共通関数 store_request_and_open_neotree に変更はありません)
local function store_request_and_open_neotree(payload)
  -- [! 2. ツリーを開く前に、展開状態キャッシュをクリアする]
  cmd_tree_provider.request({ capability = "uep.clear_tree_state" })
  uep_log.debug("Cleared tree expanded state for new :UEP module_tree request.")

  -- consumer ID を直接指定
  unl_context.use("UEP"):key("pending_request:" .. "neo-tree-uproject"):set("payload", payload)
  uep_log.info("Request stored for neo-tree (module_tree). Module: %s, Deps: %s",
               payload.target_module or "Picker", payload.deps_flag)

  unl_events.publish(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, payload )

  local ok, neo_tree_cmd = pcall(require, "neo-tree.command")
  if ok then
    neo_tree_cmd.execute({ source = "uproject", action = "focus" })
  else
     uep_log.warn("neo-tree command not found.")
  end
end

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
    store_request_and_open_neotree(payload)
  else
    -- モジュール名が指定されていなければ、ピッカーで選択させる
    uep_log.info("Fetching module list for picker...")

    -- ▼▼▼ モジュールリスト取得ロジック修正 ▼▼▼
    -- (core.utils.get_project_maps を使う代わりに、ここで直接キャッシュを読む)
    local project_display_name = vim.fn.fnamemodify(project_root, ":t")
    local project_registry_info = projects_cache.get_project_info(project_display_name)
    if not project_registry_info or not project_registry_info.components then
        return uep_log.error("Module list fetch failed: Project not in registry.")
    end

    local all_modules_picker = {}
    for _, comp_name in ipairs(project_registry_info.components) do
        local p_cache = project_cache.load(comp_name .. ".project.json")
        if p_cache then
             for _, mtype in ipairs({"runtime_modules", "developer_modules", "editor_modules", "programs_modules"}) do
                 if p_cache[mtype] then
                     for mod_name, mod_meta in pairs(p_cache[mtype]) do
                         -- owner_name が mod_meta に含まれている前提 (graph.lua でコピー済み)
                         local owner_display = (mod_meta.owner_name == engine_name and "Engine") or (mod_meta.owner_name == game_name and "Game") or "Plugin"
                         table.insert(all_modules_picker, {
                             label = string.format("%s (%s)", mod_name, owner_display),
                             value = mod_name
                         })
                     end
                 end
             end
        end
    end
    if #all_modules_picker == 0 then return uep_log.error("Module list fetch failed: No modules found in cache.") end
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
        store_request_and_open_neotree(payload)
      end,
    })
  end
end

return M
