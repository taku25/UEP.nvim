-- lua/UEP/cmd/grep.lua (New Scope Handling)

local grep_core = require("UEP.cmd.core.grep")
local uep_log = require("UEP.logger")
-- local unl_finder = require("UNL.finder") -- Use utils instead
local uep_config = require("UEP.config")
local core_utils = require("UEP.cmd.core.utils") -- ★ Use utils
local fs = require("vim.fs") -- ★ Require fs

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  opts = opts or {}

  -- ▼▼▼ Parse new scope argument (Default: runtime) ▼▼▼
  local requested_scope = "runtime"
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }
  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          log.warn("Invalid scope argument '%s' for grep. Defaulting to 'runtime'.", opts.scope)
          -- Keep default "runtime"
      end
  end
  log.info("Executing :UEP grep with scope=%s", requested_scope)
  -- ▲▲▲ Scope parsing complete ▲▲▲

  -- ▼▼▼ Determine search paths based on scope ▼▼▼
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("grep: Failed to get project maps: %s", tostring(maps))
      return vim.notify("Error getting project info for grep.", vim.log.levels.ERROR)
    end

    local search_paths = {}
    local project_root = maps.project_root
    local engine_root = maps.engine_root

    if not project_root then
        return log.error("grep: Project root not found in maps.")
    end

    -- Helper to add existing directories under a root path
    local function add_standard_dirs(root, subdirs)
        local base = (root == engine_root) and fs.joinpath(engine_root, "Engine") or project_root
        for _, subdir in ipairs(subdirs or {"Source", "Plugins", "Config", "Shaders", "Programs"}) do -- Default dirs
            local path = fs.joinpath(base, subdir)
            if vim.fn.isdirectory(path) == 1 then
                table.insert(search_paths, path)
            end
        end
    end

    if requested_scope == "game" then
      -- Game scope: Project dirs only
      add_standard_dirs(project_root)
    elseif requested_scope == "engine" then
      -- Engine scope: Engine dirs only
      if engine_root then add_standard_dirs(engine_root)
      else log.warn("grep: Engine root not found for Engine scope.") end
    elseif requested_scope == "full" then
       -- Full scope: Both Project and Engine dirs
      add_standard_dirs(project_root)
      if engine_root then add_standard_dirs(engine_root)
      else log.warn("grep: Engine root not found for Full scope.") end
    else -- Runtime, Developer, Editor (Treat similarly for grep? Or filter based on module type?)
       -- For simplicity in grep, let's treat Runtime/Dev/Editor like Full for now.
       -- Grep usually searches code regardless of its specific type.
       -- If finer filtering is needed later, we'd need to get module lists based on scope
       -- and add only their module_root paths to search_paths.
       log.debug("grep: Using 'Full' directory search scope for Runtime/Developer/Editor.")
       add_standard_dirs(project_root)
       if engine_root then add_standard_dirs(engine_root)
       else log.warn("grep: Engine root not found.") end
    end

    -- Remove duplicates (though unlikely with this approach)
    local seen = {}; local unique_paths = {}
    for _, path in ipairs(search_paths) do if not seen[path] then table.insert(unique_paths, path); seen[path] = true end end
    search_paths = unique_paths

    if #search_paths == 0 then
        return log.warn("grep: No valid search paths found for scope '%s'.", requested_scope)
    end
    log.debug("grep: Determined search paths: %s", vim.inspect(search_paths))
    -- ▲▲▲ Search path determination complete ▲▲▲

    -- Call the core grep function
    grep_core.start_live_grep({
      search_paths = search_paths,
      title = string.format("Live Grep (%s)", requested_scope:gsub("^%l", string.upper)),
      initial_query = "", -- Could add argument parsing for initial query later
    })
  end)
end

return M
