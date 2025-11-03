-- lua/UEP/cmd/program_files.lua (モジュールキャッシュ対応版)

local module_cache = require("UEP.cache.module") -- ★ モジュールキャッシュを使用
local core_utils = require("UEP.cmd.core.utils") -- ★ 修正された utils を使用
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  log.debug("Executing :UEP program_files...")
  local start_time = os.clock()

  -- STEP 1: プロジェクトの全体マップを取得
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("program_files: Failed to get project maps: %s", tostring(maps))
      return vim.notify("Error getting project maps.", vim.log.levels.ERROR)
    end

    -- STEP 2: programs_modules_map を取得
    local programs_modules = maps.programs_modules_map or {}
    local program_module_count = vim.tbl_count(programs_modules)
    log.debug("program_files: Found %d program modules.", program_module_count)

    if program_module_count == 0 then
      log.info("program_files: No program modules found in this project cache.")
      return vim.notify("No program modules found.", vim.log.levels.INFO)
    end

    -- STEP 3: 全プログラムモジュールのキャッシュをロードし、ファイルを集約
    local program_files_with_context = {}
    local modules_processed = 0
    for mod_name, mod_meta in pairs(programs_modules) do
        local mod_cache_data = module_cache.load(mod_meta)
        if mod_cache_data and mod_cache_data.files then
            for category, files in pairs(mod_cache_data.files) do
                for _, file_path in ipairs(files) do
                    table.insert(program_files_with_context, {
                        file_path = file_path,
                        module_name = mod_name,
                        module_root = mod_meta.module_root, -- ★ module_root を追加
                        category = category,
                    })
                end
            end
        elseif mod_cache_data == nil then
            log.warn("program_files: Module cache not found for program module '%s'. Run :UEP refresh!", mod_name)
        end
        modules_processed = modules_processed + 1
    end

    local total_files_found = #program_files_with_context
    log.debug("program_files: Aggregated %d files from %d program modules.", total_files_found, modules_processed)

    if total_files_found == 0 then
      log.info("program_files: No files found within the program modules.")
      return vim.notify("No program files found.", vim.log.levels.INFO)
    end

    -- STEP 4: ピッカーで表示するために整形する
    local picker_items = {}
    for _, item in ipairs(program_files_with_context) do
      -- プログラムモジュールの場合、module_root が nil の可能性がある？ -> ないはず (Build.cs がある前提)
      if item.module_root then
          local relative_path = core_utils.create_relative_path(item.file_path, item.module_root)
          table.insert(picker_items, {
            -- 表示形式: ModuleName/RelativePath (ModuleName)
            display = string.format("%s/%s (%s)", item.module_name, relative_path, item.module_name),
            value = item.file_path, -- ★ value にフルパスを直接設定 (files コマンドと形式を合わせる)
            filename = item.file_path,
          })
      else
           log.warn("program_files: Missing module_root for file %s in module %s", item.file_path, item.module_name)
           -- ルートがない場合はフルパスを表示
           table.insert(picker_items, {
               display = item.file_path,
               value = item.file_path,
               filename = item.file_path,
           })
      end
    end
    table.sort(picker_items, function(a, b) return a.display < b.display end)

    local end_time = os.clock()
    log.info("program_files: Finished processing in %.4f seconds. Showing picker with %d items.",
             end_time - start_time, #picker_items)

    -- STEP 5: ピッカーを起動
    unl_picker.pick({
      kind = "uep_program_files",
      title = "ﬧ Programs Files",
      items = picker_items,
      conf = uep_config.get(),
      preview_enabled = true,
      devicons_enabled = true,
      on_submit = function(selection)
        -- ★ value がフルパスになったので、そのまま使う
        if selection and selection ~= "" then
          pcall(vim.cmd.edit, vim.fn.fnameescape(selection))
        end
      end,
    })
  end)
end

return M
