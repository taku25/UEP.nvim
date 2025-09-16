-- lua/UEP/cmd/module_files.lua (リファクタリング版)

local files_core = require("UEP.cmd.core.files")
local unl_picker = require("UNL.backend.picker")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")
local projects_cache = require("UEP.cache.projects")
local unl_finder = require("UNL.finder")

local M = {}

local function show_file_picker(items, project_root)
  -- (この関数に変更はありません)
  if not items or #items == 0 then
    uep_log.get().info("No matching files found for this module.")
    return
  end
  local picker_items = {}
  local root_prefix = project_root .. "/"
  for _, file_path in ipairs(items) do
    table.insert(picker_items, {
      label = file_path:gsub(root_prefix, ""),
      value = { filename = file_path, text = file_path:gsub(root_prefix, "") }
    })
  end
  table.sort(picker_items, function(a, b) return a.label < b.label end)
  unl_picker.pick({
    kind = "module_file_location",
    title = "  Module Files",
    items = picker_items,
    preview_enabled = true, -- プレビューを有効化
    conf = uep_config.get(),
    logger_name = uep_log.name,
    on_submit = function(selection)
      if selection and selection.filename then
        pcall(vim.cmd.edit, selection.filename)
      end
    end
  })
end

-- ▼▼▼ メインロジックを全面的に書き直し ▼▼▼
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 実際のファイル検索と表示を行う関数
  local function search_and_display(module_name)
    log.info("Searching files for module: %s", module_name)
    files_core.get_files_for_single_module(vim.loop.cwd(), module_name, function(ok, files)
      if not ok then
        log.error("Failed to get module files: %s", tostring(files))
        return
      end
      local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
      show_file_picker(files, project_root)
    end)
  end
  
  -- `!`付きの場合、refreshを先に実行する関数
  local function refresh_and_display(module_name)
    local refresh_cmd = "UEP refresh!"
    log.info("Bang detected. Running '%s' first...", refresh_cmd)
    
    local sub_id
    sub_id = unl_events.subscribe(unl_types.ON_AFTER_REFRESH_COMPLETED, function()
      unl_events.unsubscribe(sub_id)
      log.info("Refresh completed. Now searching module files.")
      vim.schedule(function()
        search_and_display(module_name)
      end)
    end)
    vim.api.nvim_command(refresh_cmd)
  end

  local main_logic_handler = opts.has_bang and refresh_and_display or search_and_display
  
  -- メインの実行フロー
  if opts.module_name then
    -- 引数でモジュール名が指定されている場合
    main_logic_handler(opts.module_name)
  else
    -- 引数がない場合、モジュール選択ピッカーを表示
    local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
    local project_display_name = vim.fn.fnamemodify(project_root, ":t")
    local project_registry_info = projects_cache.get_project_info(project_display_name)
    if not project_registry_info then return log.error("Project not in registry.") end
    
    local all_module_names = {}
    for _, comp_name in ipairs(project_registry_info.components) do
      local p_cache = require("UEP.cache.project").load(comp_name .. ".project.json")
      if p_cache and p_cache.modules then
        for mod_name, _ in pairs(p_cache.modules) do
          table.insert(all_module_names, mod_name)
        end
      end
    end
    table.sort(all_module_names)
    
    unl_picker.pick({
      kind = "module_select",
      title = "Select a Module",
      items = all_module_names,
      conf = uep_config.get(),
      on_submit = function(selected_module_name)
        if selected_module_name then
          main_logic_handler(selected_module_name)
        end
      end,
      logger_name = uep_log.name,
    })
  end
end
-- ▲▲▲ ここまで ▲▲▲

return M
