-- lua/UEP/cmd/program_files.lua (重複排除ロジック追加版)

local module_cache = require("UEP.cache.module")
local core_utils = require("UEP.cmd.core.utils")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

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

    local program_files_with_context = {}
    local modules_processed = 0

    -- STEP 2: "Program" 実モジュール (Build.cs持ち) のスキャン
    local programs_modules = maps.programs_modules_map or {}
    local program_module_count = vim.tbl_count(programs_modules)
    log.debug("program_files: Found %d 'Program' modules.", program_module_count)
    
    for mod_name, mod_meta in pairs(programs_modules) do
        local mod_cache_data = module_cache.load(mod_meta)
        
        -- ★ "programs" カテゴリのみをスキャン
        if mod_cache_data and mod_cache_data.files and mod_cache_data.files.programs then
            log.trace("Scanning 'programs' category for Program Module: %s", mod_name)
            for _, file_path in ipairs(mod_cache_data.files.programs) do
                table.insert(program_files_with_context, {
                    file_path = file_path,
                    module_name = mod_name,
                    module_root = mod_meta.module_root,
                    category = "programs",
                })
            end
        elseif mod_cache_data == nil then
            log.warn("program_files: Module cache not found for program module '%s'. Run :UEP refresh!", mod_name)
        end
        modules_processed = modules_processed + 1
    end
    
    -- STEP 3a: Game と Plugin の "疑似モジュール" スキャン
    for comp_name_hash, comp_meta in pairs(maps.all_components_map) do
      if comp_meta.type == "Game" or comp_meta.type == "Plugin" then
        local pseudo_meta = { name = comp_meta.display_name, module_root = comp_meta.root_path }
        local pseudo_cache_data = module_cache.load(pseudo_meta)
        
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
    if maps.engine_root then
        local engine_programs_root = fs.joinpath(maps.engine_root, "Engine", "Source", "Programs")
        local pseudo_meta = { name = "_EnginePrograms", module_root = engine_programs_root }
        local pseudo_cache_data = module_cache.load(pseudo_meta)

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

    -- ▼▼▼ [!!! STEP 3c: 重複ファイルパスを除外 !!!] ▼▼▼
    local total_before_dedupe = #program_files_with_context
    local seen_paths = {}
    local unique_files_with_context = {}
    for _, item in ipairs(program_files_with_context) do
        if not seen_paths[item.file_path] then
            table.insert(unique_files_with_context, item)
            seen_paths[item.file_path] = true
        end
    end
    program_files_with_context = unique_files_with_context -- [!] リストを入れ替える
    local total_after_dedupe = #program_files_with_context
    log.debug("program_files: Deduplicated list. Before: %d, After: %d", total_before_dedupe, total_after_dedupe)
    -- ▲▲▲ [修正完了] ▲▲▲

    local total_files_found = #program_files_with_context
    -- log.debug("program_files: Aggregated %d files from %d program modules (and pseudo-modules).", total_files_found, modules_processed)

    if total_files_found == 0 then
      log.info("program_files: No files found within the program modules.")
      return vim.notify("No program files found.", vim.log.levels.INFO)
    end

    -- STEP 4: ピッカーで表示するために整形する
    local picker_items = {}
    -- [!] ユーザーのデバッグコード (インデックス `i` を表示) を反映
    for i, item in ipairs(program_files_with_context) do
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

    -- [!] ユーザーのデバッグコード (print) を反映 (string.formatを使用)
    print(string.format("Picker Items: %d, Context Items: %d", #picker_items, #program_files_with_context))
    
    table.sort(picker_items, function(a, b) return a.display < b.display end)

    local end_time = os.clock()
    log.info("program_files: Finished processing in %.4f seconds. Showing picker with %d items.",
             end_time - start_time, #picker_items)


-- 呼び出し側（program_files や UEP files を生成するコード）

local N =#picker_items -- (または 24026。リストの総数)

-- ★★★ 本当の修正：ipairs ではなく、1からNまで回す ★★★
local dense_results = {}
for i = 1, N do
  local v = picker_items[i]
  if v ~= nil then
    table.insert(dense_results, v)
  end
end
-- ★★★★★★★★★★★

    -- STEP 5: ピッカーを起動
    unl_picker.pick({
      kind = "uep_program_files",
      title = "ﬧ Programs Files",
      items = dense_results,
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
