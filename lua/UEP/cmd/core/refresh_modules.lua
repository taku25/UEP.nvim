-- lua/UEP/cmd/core/refresh_modules.lua (疑似モジュール名の重複バグ修正版)

local class_parser = require("UEP.parser.class")
local uep_config = require("UEP.config")
local uep_db = require("UEP.db.init")
local db_writer = require("UEP.db.writer")
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")
local fs = require("vim.fs")
local unl_events_ok, unl_events = pcall(require, "UNL.event.events")
local unl_types_ok, unl_event_types = pcall(require, "UNL.event.types")

local M = {}

local defaults = require("UEP.config.defaults") -- [!] デフォルト設定を読み込み

local function load_header_details_from_db(module_meta)
  local db = uep_db.get()
  if not db then return {} end
  
  local rows = db:eval([[
    SELECT f.path, c.name, c.base_class, c.line_number, c.symbol_type
    FROM classes c
    JOIN files f ON c.file_id = f.id
    JOIN modules m ON f.module_id = m.id
    WHERE m.name = ? AND m.root_path = ?
  ]], { module_meta.name, module_meta.module_root })
  
  if type(rows) ~= "table" then return {} end
  
  local details = {}
  for _, row in ipairs(rows) do
    if not details[row.path] then details[row.path] = { classes = {} } end
    table.insert(details[row.path].classes, {
      name = row.name,
      base_class = row.base_class,
      line = row.line_number,
      type = row.symbol_type
    })
  end
  return details
end

function M.create_fd_command(base_paths, type_flag)
  local conf = uep_config.get()
  
  -- confの値がnilでも、defaultsの値 (テーブル) にフォールバックする
  local exclude_dirs = conf.excludes_directory
  if type(exclude_dirs) ~= "table" then
      exclude_dirs = defaults.excludes_directory or {}
  end
  
  local fd_cmd = {
    "fd", "--full-path", "--type", type_flag, "--path-separator", "/",
    "--no-ignore" --, "--hidden"
  }
  
  -- これで exclude_dirs がテーブルであることが保証される
  for _, dir in ipairs(exclude_dirs) do table.insert(fd_cmd, "--exclude"); table.insert(fd_cmd, dir) end
  
  if type_flag == "f" then
    local extensions = conf.include_extensions
    if type(extensions) ~= "table" then
        extensions = defaults.include_extensions or {}
    end

    -- これで extensions がテーブルであることが保証される
    for _, ext in ipairs(extensions) do
      if ext ~= "uproject" and ext ~= "uplugin" then table.insert(fd_cmd, "--extension"); table.insert(fd_cmd, ext) end
    end
  end
  
  for _, path in ipairs(base_paths) do
      if vim.fn.isdirectory(path) == 1 then -- 存在確認
          table.insert(fd_cmd, "--search-path")
          table.insert(fd_cmd, path)
      end
  end

  return fd_cmd
end


function M.create_module_caches_for(modules_to_refresh_meta, all_modules_meta_by_path, all_components_map, progress, game_root, engine_root, on_done)
  local log = uep_log.get()
  local modules_to_refresh_list = vim.tbl_values(modules_to_refresh_meta)
  local total_count = #modules_to_refresh_list

  -- ... (PSEUDO_MODULES の構築) ...
  local PSEUDO_MODULES = {}
  PSEUDO_MODULES["_EngineConfig"] = { name = "_EngineConfig", root = fs.joinpath(engine_root, "Engine", "Config"), type = "Config" }
  PSEUDO_MODULES["_EngineShaders"] = { name = "_EngineShaders", root = fs.joinpath(engine_root, "Engine", "Shaders"), type = "Shader" }
  PSEUDO_MODULES["_EnginePrograms"] = { name = "_EnginePrograms", root = fs.joinpath(engine_root, "Engine", "Source", "Programs"), type = "Program" }
  
  for comp_name_hash, comp_meta in pairs(all_components_map) do
    if comp_meta.type == "Game" or comp_meta.type == "Plugin" then
      
      -- ▼▼▼ [ここから修正] ▼▼▼
      -- display_name が "xxx" で重複するのを防ぐため、
      -- "Game_xxx" や "Plugin_xxx" のようにコンポーネントタイプでプレフィックスを付ける
      local pseudo_name = comp_meta.type .. "_" .. comp_meta.display_name
      -- ▲▲▲ [修正完了] ▲▲▲
      
      local pseudo_root = comp_meta.root_path
      if PSEUDO_MODULES[pseudo_name] then
        log.warn("Duplicate pseudo-module name detected: %s. Skipping component: %s", pseudo_name, comp_name_hash)
      elseif not pseudo_root then
        log.warn("Pseudo-module '%s' has nil root_path. Skipping.", pseudo_name)
      else
        PSEUDO_MODULES[pseudo_name] = { name = pseudo_name, root = pseudo_root, type = comp_meta.type }
      end
    end
  end

  progress:stage_define("module_file_scan", 1)
  progress:stage_update("module_file_scan", 0, ("Scanning files for %d modules (+ %d components)..."):format(total_count, vim.tbl_count(PSEUDO_MODULES)))

  local top_level_search_paths = { game_root, engine_root }
  if not game_root or not engine_root then log.error("game_root or engine_root is nil."); if on_done then on_done(false) end; return end
  local fd_cmd_files = M.create_fd_command(top_level_search_paths, "f")
  local fd_cmd_dirs = M.create_fd_command(top_level_search_paths, "d")

  local all_found_files = {}
  local all_found_dirs = {}
  local files_stderr = {}

  local line_buffer_files = "" -- [!] ファイルスキャン用のバッファ

  local job_ok, job_id_or_err = pcall(vim.fn.jobstart, fd_cmd_files, {
    stdout_buffered = true, stderr_buffered = true,
    
    on_stdout = function(_, data, _)
      if not data then return end
      data[1] = line_buffer_files .. (data[1] or "")
      local last_line_index = #data
      local last_line = data[last_line_index]
      
      if last_line and last_line ~= "" and not last_line:find("[\r\n]$") then
        line_buffer_files = table.remove(data, last_line_index)
      else
        line_buffer_files = ""
      end

      for _, line in ipairs(data) do
        if line and line ~= "" then
          table.insert(all_found_files, line)
        end
      end
    end,

    on_stderr = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(files_stderr, line) end end end end,
    
    on_exit = function(_, files_code)
      if line_buffer_files and line_buffer_files ~= "" then
        table.insert(all_found_files, line_buffer_files)
        line_buffer_files = ""
      end

      if files_code ~= 0 then log.error("fd (files) command failed: %s", table.concat(files_stderr, "\n")); if on_done then on_done(false) end; return end

      vim.schedule(function()
        local dirs_stderr = {}
        
        local line_buffer_dirs = "" -- [!] ディレクトリ スキャン用のバッファ

        local job2_ok, job2_id_or_err = pcall(vim.fn.jobstart, fd_cmd_dirs, {
          stdout_buffered = true, stderr_buffered = true,
          
          on_stdout = function(_, data, _)
            if not data then return end
            data[1] = line_buffer_dirs .. (data[1] or "")
            local last_line_index = #data
            local last_line = data[last_line_index]
            
            if last_line and last_line ~= "" and not last_line:find("[\r\n]$") then
              line_buffer_dirs = table.remove(data, last_line_index)
            else
              line_buffer_dirs = ""
            end
            
            for _, line in ipairs(data) do
              if line and line ~= "" then
                table.insert(all_found_dirs, line)
              end
            end
          end,
          
          on_stderr = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(dirs_stderr, line) end end end end,
          
          on_exit = function(_, dirs_code)
            if line_buffer_dirs and line_buffer_dirs ~= "" then
              table.insert(all_found_dirs, line_buffer_dirs)
              line_buffer_dirs = ""
            end

            if dirs_code ~= 0 then log.error("fd (dirs) command failed: %s", table.concat(dirs_stderr, "\n")); if on_done then on_done(false) end; return end

            progress:stage_update("module_file_scan", 1, ("File scan complete (%d files, %d dirs). Classifying..."):format(#all_found_files, #all_found_dirs))
            
            local files_by_path_key = {}
            local dirs_by_path_key = {}
            
            for _, pseudo in pairs(PSEUDO_MODULES) do
              files_by_path_key[pseudo.root] = { source={}, config={}, shader={}, programs={}, other={}, content={} }
              dirs_by_path_key[pseudo.root] = { source={}, config={}, shader={}, programs={}, other={}, content={} }
            end
            for path, meta in pairs(modules_to_refresh_meta) do
              files_by_path_key[path] = { source={}, config={}, shader={}, programs={}, other={}, content={} }
              dirs_by_path_key[path] = { source={}, config={}, shader={}, programs={}, other={}, content={} }
            end

            local sorted_real_module_roots = vim.tbl_keys(modules_to_refresh_meta)
            table.sort(sorted_real_module_roots, function(a,b) return #a > #b end)
            
            local sorted_pseudo_roots = {}
            for _, pseudo in pairs(PSEUDO_MODULES) do table.insert(sorted_pseudo_roots, pseudo.root) end
            table.sort(sorted_pseudo_roots, function(a,b) return #a > #b end)

            -- ▼▼▼ ファイル振り分け ▼▼▼
            for _, file in ipairs(all_found_files) do
              local assigned = false
              -- 1. 実際のモジュール
              for _, mod_root in ipairs(sorted_real_module_roots) do
                if file:find(mod_root, 1, true) then
                  local category = core_utils.categorize_path(file)
                  if category ~= "uproject" and category ~= "uplugin" then
                    if files_by_path_key[mod_root] then
                      if not files_by_path_key[mod_root][category] then files_by_path_key[mod_root][category] = {} end
                      table.insert(files_by_path_key[mod_root][category], file)
                    else
                      log.warn("refresh_modules: files_by_path_key key missing for %s", mod_root)
                    end
                  end
                  assigned = true; break
                end
              end
              -- 2. 疑似モジュール
              if not assigned then
                for _, pseudo_root in ipairs(sorted_pseudo_roots) do
                  if file:find(pseudo_root, 1, true) then
                    
                    local is_engine_programs = pseudo_root:find("Engine/Source/Programs", 1, true)
                    local should_check_source_exclusion = true
                    if is_engine_programs then
                      should_check_source_exclusion = false
                    end

                    if (not should_check_source_exclusion) or (not file:find(fs.joinpath(pseudo_root, "Source"), 1, true)) then
                      local category = core_utils.categorize_path(file)
                      if files_by_path_key[pseudo_root] then
                        if not files_by_path_key[pseudo_root][category] then files_by_path_key[pseudo_root][category] = {} end
                        table.insert(files_by_path_key[pseudo_root][category], file)
                      end
                    end
                    assigned = true; break
                  end
                end
              end
            end
            
            -- ▼▼▼ ディレクトリ振り分け ▼▼▼
            for _, dir in ipairs(all_found_dirs) do
                local assigned = false
                -- 1. 実際のモジュール
                for _, mod_root in ipairs(sorted_real_module_roots) do
                    if dir:find(mod_root, 1, true) then
                        local category = core_utils.categorize_path(dir)
                        if category ~= "uproject" and category ~= "uplugin" then
                            if dirs_by_path_key[mod_root] then
                                if not dirs_by_path_key[mod_root][category] then dirs_by_path_key[mod_root][category] = {} end
                                table.insert(dirs_by_path_key[mod_root][category], dir)
                            else
                                log.warn("refresh_modules: dirs_by_path_key key missing for %s", mod_root)
                            end
                        end
                        assigned = true; break
                    end
                end
                -- 2. 疑似モジュール
                if not assigned then
                    for _, pseudo_root in ipairs(sorted_pseudo_roots) do
                        if dir:find(pseudo_root, 1, true) then
                            local is_engine_programs = pseudo_root:find("Engine/Source/Programs", 1, true)
                            local should_check_source_exclusion = true
                            if is_engine_programs then
                                should_check_source_exclusion = false
                            end

                            if (not should_check_source_exclusion) or (not dir:find(fs.joinpath(pseudo_root, "Source"), 1, true)) then
                                local category = core_utils.categorize_path(dir)
                                if dirs_by_path_key[pseudo_root] then
                                    if not dirs_by_path_key[pseudo_root][category] then dirs_by_path_key[pseudo_root][category] = {} end
                                    table.insert(dirs_by_path_key[pseudo_root][category], dir)
                                end
                            end
                            assigned = true; break
                        end
                    end
                end
            end
            
            progress:stage_define("header_analysis", #all_found_files)
            local all_existing_header_details = {}
            for path, mod_meta in pairs(all_modules_meta_by_path) do
                if not modules_to_refresh_meta[path] then
                  local details = load_header_details_from_db(mod_meta)
                  for fp, d in pairs(details) do all_existing_header_details[fp] = d end
                end
            end
            for _, pseudo in pairs(PSEUDO_MODULES) do
                local pseudo_meta = { name=pseudo.name, module_root=pseudo.root }
                local details = load_header_details_from_db(pseudo_meta)
                for fp, d in pairs(details) do all_existing_header_details[fp] = d end
            end

            local headers_to_parse = {}
            for _, file in ipairs(all_found_files) do
              if file:match("%.h$") and not file:find("NoExportTypes.h", 1, true) then
                table.insert(headers_to_parse, file)
              end
            end
            log.debug("Identified %d header files to parse out of %d total files found.", #headers_to_parse, #all_found_files)

            class_parser.parse_headers_async(all_existing_header_details, headers_to_parse, progress, function(ok, header_details_by_file)
              if not ok then log.error("Header parsing failed, aborting module cache save."); if on_done then on_done(false) end; return end

              progress:stage_define("module_cache_save", total_count + vim.tbl_count(PSEUDO_MODULES))
              local saved_count = 0
              log.debug("create_module_caches_for: Starting save loop for %d modules.", total_count)

              for path, module_meta in pairs(modules_to_refresh_meta) do 
                saved_count = saved_count + 1
                local module_name = module_meta.name
                progress:stage_update("module_cache_save", saved_count, ("Saving: %s [%d/%d]"):format(module_name, saved_count, total_count))
                
                if module_name == "Engine" then log.debug("create_module_caches_for: Processing 'Engine' module for saving...") end

                local module_files_data = files_by_path_key[path]
                local module_dirs_data = dirs_by_path_key[path]
                if module_files_data and module_dirs_data then
                  local module_header_details = {}
                  if header_details_by_file then
                    if module_files_data.source then
                      for _, file in ipairs(module_files_data.source) do
                        if header_details_by_file[file] then module_header_details[file] = header_details_by_file[file] end
                      end
                    end
                  end
                  local data_to_save = { files = module_files_data, directories = module_dirs_data, header_details = module_header_details }
                  
                  db_writer.save_module_files(module_meta, module_files_data, module_header_details, module_dirs_data)
                  if module_name == "Engine" then log.debug("create_module_caches_for: module_cache.save SUCCEEDED for 'Engine'") end
                else
                  log.debug("create_module_caches_for: Saving empty cache for '%s' (data missing in map)", module_name)
                  db_writer.save_module_files(module_meta, {}, {}, {})
                end
              end
              
              log.debug("create_module_caches_for: Saving %d pseudo-modules...", vim.tbl_count(PSEUDO_MODULES))
              for _, pseudo in pairs(PSEUDO_MODULES) do
                  saved_count = saved_count + 1
                  progress:stage_update("module_cache_save", saved_count, ("Saving: %s [%d/%d]"):format(pseudo.name, saved_count, total_count + vim.tbl_count(PSEUDO_MODULES)))
                  local pseudo_files_data = files_by_path_key[pseudo.root]
                  local pseudo_dirs_data = dirs_by_path_key[pseudo.root]
                  if pseudo_files_data and pseudo_dirs_data then
                      local pseudo_header_details = {}
                      if header_details_by_file then
                        for category, files in pairs(pseudo_files_data) do
                            for _, file in ipairs(files) do
                              if header_details_by_file[file] then pseudo_header_details[file] = header_details_by_file[file] end
                            end
                        end
                      end
                      local pseudo_meta = { name = pseudo.name, module_root = pseudo.root, type = pseudo.type }
                      db_writer.save_module_files(pseudo_meta, pseudo_files_data, pseudo_header_details, pseudo_dirs_data)
                  else
                      log.debug("create_module_caches_for: No files/dirs found for pseudo-module '%s'. Saving empty.", pseudo.name)
                      local pseudo_meta = { name = pseudo.name, module_root = pseudo.root, type = pseudo.type }
                      db_writer.save_module_files(pseudo_meta, {}, {}, {})
                  end
              end

              progress:stage_update("module_cache_save", saved_count, "All module caches saved.")
              if on_done then on_done(true) end
            end)
          end,
        })
        if not job2_ok then log.error("Failed to start fd (dirs) job: %s", tostring(job2_id_or_err)); if on_done then on_done(false) end end
      end)
    end,
  })
  if not job_ok then log.error("Failed to start fd (files) job: %s", tostring(job_id_or_err)); if on_done then on_done(false) end end
end

-- ( ... update_single_module_cache 関数は変更なし ... )
function M.update_single_module_cache(module_name, on_complete)
  local log = uep_log.get()
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("update_single_module_cache: Failed to get project maps: %s", tostring(maps))
      if on_complete then on_complete(false) end
      return
    end
    local module_meta = maps.all_modules_map[module_name]
    if not module_meta or not module_meta.module_root then
      log.error("Cannot update module '%s': not found in cache or 'module_root' is missing.", module_name)
      if on_complete then on_complete(false) end
      return
    end
    log.info("Starting lightweight refresh for module: %s (Path: %s)", module_name, module_meta.module_root)
    local fd_cmd_files = M.create_fd_command({ module_meta.module_root }, "f")
    local fd_cmd_dirs = M.create_fd_command({ module_meta.module_root }, "d")
    local new_files = {}
    local new_dirs = {}
    local files_stderr = {}
    local files_job_id = vim.fn.jobstart(fd_cmd_files, {
      stdout_buffered = true, stderr_buffered = true,
      on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(new_files, line) end end end end,
      on_stderr = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(files_stderr, line) end end end end,
      on_exit = function(_, files_code)
        if files_code ~= 0 then
          log.error("fd (files) failed for module '%s': %s", module_name, table.concat(files_stderr, "\n"))
          if on_complete then on_complete(false) end
          return
        end
        vim.schedule(function()
          local dirs_stderr = {}
          local dirs_job_id = vim.fn.jobstart(fd_cmd_dirs, {
            stdout_buffered = true, stderr_buffered = true,
            on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(new_dirs, line) end end end end,
            on_stderr = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(dirs_stderr, line) end end end end,
            on_exit = function(_, dirs_code)
              if dirs_code ~= 0 then
                log.error("fd (dirs) failed for module '%s': %s", module_name, table.concat(dirs_stderr, "\n"))
                if on_complete then on_complete(false) end
                return
              end
              log.debug("Lightweight scan found %d files and %d dirs for '%s'", #new_files, #new_dirs, module_name)
              local files_by_category = { source = {}, config = {}, shader = {}, programs = {}, other = {}, content = {} }
              local dirs_by_category = { source = {}, config = {}, shader = {}, programs = {}, other = {}, content = {} }
              local headers_to_parse = {}
              for _, file in ipairs(new_files) do
                local category = core_utils.categorize_path(file)
                if category ~= "uproject" and category ~= "uplugin" then
                  if not files_by_category[category] then files_by_category[category] = {} end
                  table.insert(files_by_category[category], file)
                  if file:match("%.h$") and not file:find("NoExportTypes.h", 1, true) then
                    table.insert(headers_to_parse, file)
                  end
                end
              end
              for _, dir in ipairs(new_dirs) do
                local category = core_utils.categorize_path(dir)
                if category ~= "uproject" and category ~= "uplugin" then
                  if not dirs_by_category[category] then dirs_by_category[category] = {} end
                  table.insert(dirs_by_category[category], dir)
                end
              end
              local existing_header_details = load_header_details_from_db(module_meta)
              local dummy_progress = { stage_define = function() end, stage_update = function() end, }
              class_parser.parse_headers_async(existing_header_details, headers_to_parse, dummy_progress, function(ok, header_details_by_file)
                if not ok then
                  log.error("Header parsing failed for lightweight refresh of '%s'.", module_name)
                  if on_complete then on_complete(false) end
                  return
                end
                local data_to_save = { files = files_by_category, directories = dirs_by_category, header_details = header_details_by_file or {}, }
                db_writer.save_module_files(module_meta, files_by_category, header_details_by_file or {}, dirs_by_category)
                log.info("Lightweight cache update for module '%s' succeeded.", module_name)
                if on_complete then on_complete(true) end
              end)
            end,
          })
          if dirs_job_id <= 0 then
            log.error("Failed to start fd (dirs) for module '%s' (job_id: %d)", module_name, dirs_job_id)
            if on_complete then on_complete(false) end
          end
        end)
      end,
    })
    if files_job_id <= 0 then
      log.error("AFiled to start fd (files) for module '%s' (job_id: %d)", module_name, files_job_id)
      if on_complete then on_complete(false) end
    end
  end)
end

return M
