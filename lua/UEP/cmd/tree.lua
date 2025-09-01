local uep_log = require("UEP.logger")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local unl_finder = require("UNL.finder")

local M = {}

function M.execute(opts)
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    return uep_log.get().error("Not in an Unreal Engine project.")
  end
  
  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject, {})

  unl_events.publish(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, {
    project_root = project_root,
    engine_root = engine_root,
    -- ★ ここで引数を解釈して渡す
    all_depth = (opts.deps_flag == "--all-deps"), 
    target_module = nil,
  })

  local ok, neo_tree_cmd = pcall(require, "neo-tree.command")
  if ok then
    neo_tree_cmd.execute({ source = "uproject", action = "focus" })
  end
end

return M
