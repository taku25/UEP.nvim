-- lua/UEP/cmd/find_module.lua

local derived_core = require("UEP.cmd.core.derived")
local core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")
local unl_picker = require("UNL.picker")
local uep_config = require("UEP.config")

local M = {}

local function copy_module_name(target_file_path)
  local log = uep_log.get()
  
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return log.error("Could not get project maps: %s", tostring(maps))
    end

    local module_info = core_utils.find_module_for_path(target_file_path, maps.all_modules_map)
    
    if module_info and module_info.name then
      local mod_name = module_info.name
      
      -- ★修正: モジュール名をダブルクォーテーションで囲む
      local text_to_copy = string.format('"%s"', mod_name)
      
      -- クリップボードにコピー
      vim.fn.setreg('+', text_to_copy)
      vim.fn.setreg('"', text_to_copy)
      
      vim.notify(string.format("Copied module name %s to clipboard.", text_to_copy), vim.log.levels.INFO)
      log.info("Copied module %s for file '%s'", text_to_copy, target_file_path)
    else
      vim.notify("Could not identify module for this file.", vim.log.levels.WARN)
      log.warn("Module not found for file: %s", target_file_path)
    end
  end)
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  local search_opts = { scope = "Full" } 
  
  if opts.has_bang then
      log.info("Bang detected! Regenerating class cache...")
  end

  derived_core.get_all_classes(search_opts, function(all_classes)
    if not all_classes or #all_classes == 0 then
      return log.error("No classes found. Please run :UEP refresh.")
    end

    local picker_items = {}
    for _, class_info in ipairs(all_classes) do
      table.insert(picker_items, {
        display = string.format("%s (%s)", class_info.class_name, class_info.symbol_type or "class"),
        value = class_info.file_path,
        filename = class_info.file_path,
        kind = class_info.symbol_type
      })
    end

    unl_picker.open({
      kind = "uep_find_module",
      title = "Select Class to Find Module",
      items = picker_items,
      conf = uep_config.get(),
      preview_enabled = true,
      on_submit = function(file_path)
        if file_path then
          copy_module_name(file_path)
        end
      end,
    })
  end)
end

return M

