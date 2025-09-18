local files_core = require("UEP.cmd.core.files")
local unl_picker = require("UNL.backend.picker")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")
local projects_cache = require("UEP.cache.projects")
local unl_finder = require("UNL.finder")
-- ★★★ 1. 汎用ユーティリティをrequireします ★★★
-- (あなたの環境に合わせてパスを修正してください e.g., "UEP.cmd.core.utils")
local uep_utils = require("UEP.cmd.core.utils") 

local M = {}

-- ★★★ 2. show_file_picker を修正します ★★★
local function show_file_picker(items, base_path)
  if not items or #items == 0 then
    uep_log.get().info("No matching files found for this module.")
    return
  end
  local picker_items = {}
  
  -- gsubの代わりに、実績のあるユーティリティ関数を使います
  for _, file_path in ipairs(items) do
    table.insert(picker_items, {
      label = uep_utils.create_relative_path(file_path, base_path),
      value = { filename = file_path, text = file_path }
    })
  end

  table.sort(picker_items, function(a, b) return a.label < b.label end)
  unl_picker.pick({
    kind = "module_file_location",
    title = " Module Files",
    items = picker_items,
    preview_enabled = true,
    devicons_enabled  = true,
    conf = uep_config.get(),
    logger_name = uep_log.name,
    on_submit = function(selection)
      if selection and selection.filename then
        pcall(vim.cmd.edit, selection.filename)
      end
    end
  })
end

-- ★★★ 3. search_and_display を修正します ★★★
local function search_and_display(module_name)
  local log = uep_log.get()
  log.info("Searching files for module: %s", module_name)

  -- STEP 1: モジュールのメタ情報を取得するために、まず `get_project_maps` を呼び出す
  uep_utils.get_project_maps(vim.loop.cwd(), function(maps_ok, maps)
    if not maps_ok then
      log.error("Failed to get project maps: %s", tostring(maps))
      return
    end
    
    local module_info = maps.all_modules_map[module_name]
    if not (module_info and module_info.module_root) then
      log.error("Could not find module root for '%s'", module_name)
      return
    end

    -- STEP 2: `get_project_maps` が成功した後、実際のファイルリストを取得
    files_core.get_files_for_single_module(vim.loop.cwd(), module_name, function(files_ok, files)
      if not files_ok then
        log.error("Failed to get module files: %s", tostring(files))
        return
      end

      -- STEP 3: モジュール名が表示されるように、モジュールルートの「親ディレクトリ」を基準パスとする
      local base_path = vim.fn.fnamemodify(module_info.module_root, ":h")
      
      -- 基準パスを使ってピッカーを表示
      show_file_picker(files, base_path)
    end)
  end)
end
  
-- (M.execute関数は変更ありません。search_and_displayを呼び出すだけです)
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()
  
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
  
  if opts.module_name then
    main_logic_handler(opts.module_name)
  else
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

return M
