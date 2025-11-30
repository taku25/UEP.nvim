local core_utils = require("UEP.cmd.core.utils")
local unl_picker = require("UNL.backend.picker")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")

local M = {}

---
-- モジュールのBuild.csファイルを選択するピッカーを表示
local function show_picker(all_modules_map)
  local log = uep_log.get()
  local picker_items = {}

  for name, meta in pairs(all_modules_map) do
    if meta.path and meta.path ~= "" then
      -- core_utils.create_relative_path を使って表示を綺麗にする
      -- (path は Build.cs のフルパス)
      local relative_path = core_utils.create_relative_path(meta.path, meta.module_root)
      
      table.insert(picker_items, {
        label = string.format("%s (%s)", name, meta.type or "Unknown"),
        display_path = relative_path,
        value = meta.path,
        filename = meta.path
      })
    end
  end

  if #picker_items == 0 then
    return log.warn("No modules with Build.cs found.")
  end

  table.sort(picker_items, function(a, b) return a.label < b.label end)

  unl_picker.pick({
    kind = "uep_build_cs",
    title = "Select Build.cs",
    items = picker_items,
    conf = uep_config.get(),
    preview_enabled = true,
    format = function(item)
      return string.format("%-30s  %s", item.label, item.display_path)
    end,
    on_submit = function(selection)
      if selection and selection ~= "" then
        vim.cmd.edit(vim.fn.fnameescape(selection))
      end
    end,
  })
end

---
-- メイン実行関数
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return log.error("Failed to get project maps: %s", tostring(maps))
    end

    -- 1. Bang (!) がある場合は強制的にピッカーを表示
    if opts.has_bang then
      return show_picker(maps.all_modules_map)
    end

    -- 2. Bangがない場合は、現在のファイルからモジュールを特定してジャンプ
    local current_file = vim.api.nvim_buf_get_name(0)
    if current_file == "" then
      log.info("No file open. Showing picker.")
      return show_picker(maps.all_modules_map)
    end

    local module_info = core_utils.find_module_for_path(current_file, maps.all_modules_map)

    if module_info and module_info.path and vim.fn.filereadable(module_info.path) == 1 then
      log.info("Opening Build.cs for module: %s", module_info.name)
      vim.cmd.edit(vim.fn.fnameescape(module_info.path))
    else
      -- 特定できなかった場合はピッカーにフォールバック
      if not module_info then
        log.warn("Could not determine module for current file. Showing picker.")
      else
        log.warn("Module found (%s), but Build.cs path is invalid. Showing picker.", module_info.name)
      end
      show_picker(maps.all_modules_map)
    end
  end)
end

return M
