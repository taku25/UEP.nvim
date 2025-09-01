local uep_log = require("UEP.logger")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local unl_finder = require("UNL.finder")
local project_cache = require("UEP.cache.project")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")

local M = {}

local function publish_and_open(payload)
  unl_events.publish(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, payload)
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
  
  local payload = {
    project_root = project_root,
    engine_root = engine_root,
    all_depth = (opts.deps_flag == "--all-deps"),
  }

  if opts.module_name then
    payload.target_module = opts.module_name
    publish_and_open(payload)
  else
    -- ... (ピッカーでモジュールを選択させるロジック) ...
    -- on_submit で選択されたモジュール名を payload.target_module にセットして publish_and_open を呼ぶ
     -- ... ピッカーのロジック ...
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
        publish_and_open(payload)
      end,
    })
  end
end

return M
