-- lua/UEP/cmd/module_grep.lua (Use get_project_maps)

local grep_core = require("UEP.cmd.core.grep")
local uep_core_utils = require("UEP.cmd.core.utils") -- ★ Use utils
local uep_log = require("UEP.logger")
local unl_picker = require("UNL.picker")
local uep_config = require("UEP.config")

local M = {}

local function start_grep_for_module(target_module_info)
  if not (target_module_info and target_module_info.module_root) then
    return uep_log.get().error("module_grep: Module info is invalid or missing 'module_root'.")
  end

  grep_core.start_live_grep({
    search_paths = { target_module_info.module_root }, -- Only the module root
    title = string.format("Live Grep (%s)", target_module_info.name),
  })
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- ★ Use get_project_maps to get module info
  uep_core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("module_grep: Failed to get project info from cache: %s", tostring(maps))
      return vim.notify("Error getting project info.", vim.log.levels.ERROR)
    end

    local all_modules_map = maps.all_modules_map

    if opts.module_name then
      local target_module_info = all_modules_map[opts.module_name]
      if target_module_info then
        start_grep_for_module(target_module_info)
      else
        log.error("module_grep: Module '%s' not found in cache.", opts.module_name)
        vim.notify(string.format("Module '%s' not found.", opts.module_name), vim.log.levels.ERROR)
      end
    else
      -- Show picker (using all_modules_map from maps)
      local picker_items = {}
      for name, meta in pairs(all_modules_map) do
         local owner_display = "Unknown"
         if maps.all_components_map and maps.all_components_map[meta.owner_name] then
             owner_display = maps.all_components_map[meta.owner_name].type -- "Game", "Engine", "Plugin"
         end
         table.insert(picker_items, {
             label = string.format("%s (%s - %s)", name, owner_display, meta.type or "N/A"),
             value = name
         })
      end
      if #picker_items == 0 then return log.error("No modules found for picker.") end
      table.sort(picker_items, function(a, b) return a.label < b.label end)

      unl_picker.open({
        kind = "uep_select_module_for_grep",
        title = "Select a Module to Grep",
        items = picker_items,
        conf = uep_config.get(),
        devicons_enabled = false, preview_enabled = false,
        on_submit = function(selected_module_name)
          if selected_module_name then
            start_grep_for_module(all_modules_map[selected_module_name])
          end
        end,
      })
    end
  end)
end

return M

