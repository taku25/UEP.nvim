-- lua/UEP/cmd/config_grep.lua (grep.lua からコピーして修正)

local grep_core = require("UEP.cmd.core.grep")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local core_utils = require("UEP.cmd.core.utils")
local fs = require("vim.fs")

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  opts = opts or {}

  local requested_scope = "runtime"
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }
  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          log.warn("Invalid scope argument '%s' for config_grep. Defaulting to 'runtime'.", opts.scope)
      end
  end
  log.info("Executing :UEP config_grep with scope=%s", requested_scope)

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("config_grep: Failed to get project maps: %s", tostring(maps))
      return vim.notify("Error getting project info for config_grep.", vim.log.levels.ERROR)
    end

    local search_paths = {}
    local project_root = maps.project_root
    local engine_root = maps.engine_root
    local all_components = maps.all_components_map or {}
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name

    -- Helper to add Config dir if exists
    local function add_config_dir(root_path, sub_path)
        local p = sub_path and fs.joinpath(root_path, sub_path, "Config") or fs.joinpath(root_path, "Config")
        if vim.fn.isdirectory(p) == 1 then
            table.insert(search_paths, p)
        end
    end

    -- 1. Project Config
    if requested_scope == "game" or requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" then
        if project_root then add_config_dir(project_root) end
    end

    -- 2. Engine Config
    if requested_scope == "engine" or requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" then
        if engine_root then add_config_dir(engine_root, "Engine") end
    end

    -- 3. Plugin Configs
    for _, comp in pairs(all_components) do
        if comp.type == "Plugin" and comp.root_path then
            local should_add = false
            
            -- Determine if we should include this plugin based on scope
            if requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" then
                should_add = true
            elseif requested_scope == "game" then
                should_add = (comp.owner_name == game_name)
            elseif requested_scope == "engine" then
                should_add = (comp.owner_name == engine_name)
            end

            if should_add then
                add_config_dir(comp.root_path)
            end
        end
    end

    -- Remove duplicates
    local seen = {}
    local unique_paths = {}
    for _, path in ipairs(search_paths) do
        if not seen[path] then
            table.insert(unique_paths, path)
            seen[path] = true
        end
    end
    search_paths = unique_paths

    if #search_paths == 0 then
        return log.warn("config_grep: No valid 'Config' directories found for scope '%s'.", requested_scope)
    end

    grep_core.start_live_grep({
      search_paths = search_paths,
      title = string.format("Live Grep Config (%s)", requested_scope:gsub("^%l", string.upper)),
      initial_query = "",
      include_extensions = { "ini" }, 
    })
  end)
end

return M
