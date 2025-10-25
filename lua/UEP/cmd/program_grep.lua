-- lua/UEP/cmd/program_grep.lua (Use get_project_maps)

local grep_core = require("UEP.cmd.core.grep")
-- local unl_finder = require("UNL.finder") -- Use utils instead
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local uep_config = require("UEP.config")
local core_utils = require("UEP.cmd.core.utils") -- ★ Use utils

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  log.info("Executing :UEP program_grep...")

  -- ★ Use get_project_maps to find program modules
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
      if not ok then
        log.error("program_grep: Failed to get project info: %s", tostring(maps))
        return vim.notify("Error getting project info.", vim.log.levels.ERROR)
      end

      local programs_modules = maps.programs_modules_map or {}
      local search_paths = {}

      for mod_name, mod_meta in pairs(programs_modules) do
          if mod_meta.module_root then
              table.insert(search_paths, mod_meta.module_root)
          else
              log.warn("program_grep: Module '%s' is missing module_root.", mod_name)
          end
      end

      if #search_paths == 0 then
        log.warn("program_grep: No program modules with valid roots found.")
        return vim.notify("No program modules found.", vim.log.levels.WARN)
      end

      log.info("program_grep: Starting grep in %d program module directories.", #search_paths)

      -- Call core grep with the identified program module roots
      grep_core.start_live_grep({
        search_paths = search_paths,
        title = "Live Grep (Programs)",
        initial_query = "",
      })
  end)
end

return M
