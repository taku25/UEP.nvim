-- lua/UEP/cmd/program_files.lua (モジュールキャッシュ ＋ 全疑似モジュール対応 決定版)

local module_cache = require("UEP.cache.module")
local core_utils = require("UEP.cmd.core.utils")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs") -- ★ fs を require

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  log.debug("Executing :UEP program_files...")
  local start_time = os.clock()

  -- STEP 1: プロジェクトの全体マップを取得 (変更なし)
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("program_files: Failed to get project maps: %s", tostring(maps))
      return vim.notify("Error getting project maps.", vim.log.levels.ERROR)
    end

    local program_files_with_context = {}
    local modules_processed = 0

    -- STEP 2: "Program" 実モジュール (Build.cs持ち) のスキャン (変更なし)
    -- (AutomationTool など)
    local programs_modules = maps.programs_modules_map or {}
    local program_module_count = vim.tbl_count(programs_modules)
    log.debug("program_files: Found %d 'Program' modules.", program_module_count)
    
    for mod_name, mod_meta in pairs(programs_modules) do
        local mod_cache_data = module_cache.load(mod_meta)
        if mod_cache_data and mod_cache_data.files then
            log.trace("Scanning all categories for Program Module: %s", mod_name)
            for category, files in pairs(mod_cache_data.files) do
                for _, file_path in ipairs(files) do
                    table.insert(program_files_with_context, {
                        file_path = file_path,
                        module_name = mod_name,
                        module_root = mod_meta.module_root,
                        category = category,
                    })
                end
            end
        elseif mod_cache_data == nil then
            log.warn("program_files: Module cache not found for program module '%s'. Run :UEP refresh!", mod_name)
        end
        modules_processed = modules_processed + 1
    end
    

    -- ▼▼▼ 修正箇所: 疑似モジュールのスキャン ▼▼▼

    -- STEP 3a: Game と Plugin の "疑似モジュール" スキャン
    -- (MyProject/Programs/ など)
    for comp_name_hash, comp_meta in pairs(maps.all_components_map) do
      if comp_meta.type == "Game" or comp_meta.type == "Plugin" then
        -- 疑似モジュールのメタデータ (refresh_modules.lua のロジックに合わせる)
        local pseudo_meta = { name = comp_meta.display_name, module_root = comp_meta.root_path }
        local pseudo_cache_data = module_cache.load(pseudo_meta)
        
        -- 疑似モジュールは "programs" カテゴリ *のみ* をスキャン
        if pseudo_cache_data and pseudo_cache_data.files and pseudo_cache_data.files.programs then
          log.trace("Scanning 'programs' category for Pseudo-Module: %s", pseudo_meta.name)
          for _, file_path in ipairs(pseudo_cache_data.files.programs) do
            table.insert(program_files_with_context, {
                file_path = file_path,
                module_name = pseudo_meta.name, 
                module_root = pseudo_meta.module_root,
                category = "programs",
            })
          end
        end
      end
    end

    -- STEP 3b: Engine の "Programs" 疑似モジュールをスキャン
    -- (UnrealBuildTool.cs など)
    if maps.engine_root then
        -- ★ _EnginePrograms 疑似モジュールを定義
        local engine_programs_root = fs.joinpath(maps.engine_root, "Engine", "Source", "Programs")
        local pseudo_meta = { name = "_EnginePrograms", module_root = engine_programs_root }
        -- ★ このメタデータで .module.json をロード
        local pseudo_cache_data = module_cache.load(pseudo_meta)

        -- ★ "programs" カテゴリ (utils.lua で分類されたもの) をスキャン
        if pseudo_cache_data and pseudo_cache_data.files and pseudo_cache_data.files.programs then
            log.trace("Scanning 'programs' category for Pseudo-Module: _EnginePrograms")
            for _, file_path in ipairs(pseudo_cache_data.files.programs) do
                table.insert(program_files_with_context, {
                    file_path = file_path,
                    module_name = "_EnginePrograms", -- 表示名
                    module_root = engine_programs_root,
                    category = "programs",
                })
            end
        end
    end
    -- ▲▲▲ 修正完了 ▲▲▲

    local total_files_found = #program_files_with_context
    log.debug("program_files: Aggregated %d files from %d program modules (and pseudo-modules).", total_files_found, modules_processed)

    if total_files_found == 0 then
      log.info("program_files: No files found within the program modules.")
      return vim.notify("No program files found.", vim.log.levels.INFO)
    end

    -- STEP 4: ピッカーで表示するために整形する (変更なし)
    local picker_items = {}
    for _, item in ipairs(program_files_with_context) do
      if item.module_root then
          local relative_path = core_utils.create_relative_path(item.file_path, item.module_root)
          table.insert(picker_items, {
            display = string.format("%s/%s (%s)", item.module_name, relative_path, item.module_name),
            value = item.file_path, 
            filename = item.file_path,
          })
      else
           log.warn("program_files: Missing module_root for file %s in module %s", item.file_path, item.module_name)
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

    -- STEP 5: ピッカーを起動 (変更なし)
    unl_picker.pick({
      kind = "uep_program_files",
      title = "ﬧ Programs Files",
      items = picker_items,
      conf = uep_config.get(),
      preview_enabled = true,
      devicons_enabled = true,
      on_submit = function(selection)
        if selection and selection ~= "" then
          pcall(vim.cmd.edit, vim.fn.fnameescape(selection))
        end
      end,
    })
  end)
end

return M
