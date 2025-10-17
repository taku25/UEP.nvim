-- lua/UEP/cmd/module_tree.lua (リファクタリング版)

local uep_log = require("UEP.logger").get()
local unl_finder = require("UNL.finder")
local unl_context = require("UNL.context")
-- ▼▼▼ 修正点: 必要なモジュールをrequire ▼▼▼
local files_core = require("UEP.cmd.core.files")
-- ▲▲▲ project_cacheは不要になったので削除 ▲▲▲
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")

local M = {}

-- (共通関数 store_request_and_open_neotree に変更はありません)
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
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject,
    {
      engine_override_path = uep_config.get().engine_path,
    })
  
  local payload = {
    project_root = project_root,
    engine_root = engine_root,
    all_deps = (opts.deps_flag == "--all-deps"),
  }

  if opts.module_name then
    payload.target_module = opts.module_name
    store_request_and_open_neotree(payload)
  else
    -- ▼▼▼ 修正点: 新しいキャッシュシステムからモジュール一覧を取得 ▼▼▼
    uep_log.info("Fetching module list for picker...")
    files_core.get_project_maps(vim.loop.cwd(), function(ok, maps)
      if not ok then
        return uep_log.error("Failed to get module list: %s", tostring(maps))
      end

      local all_modules_map = maps.all_modules_map
      local picker_items = {}
      for name, meta in pairs(all_modules_map) do
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
    end)
    -- ▲▲▲ ここまで ▲▲▲
  end
end

return M
