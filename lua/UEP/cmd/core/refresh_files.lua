-- lua/UEP/cmd/core/refresh_files.lua (修正版)

local class_parser = require("UEP.parser.class")
local uep_config = require("UEP.config")
local files_cache_manager = require("UEP.cache.files")
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")
local unl_progress = require("UNL.backend.progress")

local M = {}

-- (ヘルパー関数 create_fd_command, categorize_path に変更はありません)
M.create_fd_command = function (base_paths, type_flag)
  local conf = uep_config.get()
  local extensions = conf.include_extensions
  local include_dirs = conf.include_directory
  local exclude_dirs = conf.excludes_directory
  local dir_pattern = "(" .. table.concat(include_dirs, "|") .. ")"
  local final_regex
  if type_flag == "f" then
    local dir_pattern = "(" .. table.concat(include_dirs, "|") .. ")"
    local ext_pattern = "(" .. table.concat(extensions, "|") .. ")"
    local pattern1 = ".*[\\\\/]" .. dir_pattern .. "[\\\\/].*\\." .. ext_pattern .. "$"
    local pattern2 = ".*\\.(uproject|uplugin)$"
    final_regex = "(" .. pattern1 .. ")|(" .. pattern2 .. ")"
  else -- "d"
    final_regex = ".*[\\\\/]" .. dir_pattern .. "[\\\\/]?.*"
  end
  local fd_cmd = { "fd", "--regex", final_regex, "--full-path", "--type", type_flag, "--path-separator", "/" }
  for _, dir in ipairs(exclude_dirs) do table.insert(fd_cmd, "--exclude"); table.insert(fd_cmd, dir) end
  vim.list_extend(fd_cmd, base_paths)
  return fd_cmd
end



function M.create_component_caches_for(components_to_refresh, all_components_data, game_root, engine_root, progress, on_done)
  progress:stage_define("file_scan", 1)
  progress:stage_update("file_scan", 0, ("Scanning files for %d components..."):format(#components_to_refresh))

  if #components_to_refresh == 0 then
      uep_log.get().info("No components need file scanning.")
      if on_done then on_done(true) end
      return
  end

  local top_level_search_paths = { game_root, engine_root }
  local fd_cmd_files = M.create_fd_command(top_level_search_paths, "f")
  local fd_cmd_dirs = M.create_fd_command(top_level_search_paths, "d")

  local all_found_files = {}
  local all_found_dirs = {}

  vim.fn.jobstart(fd_cmd_files, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(all_found_files, line)
          end 
        end
      end
    end,
    on_exit = function(_, files_code)
      if files_code ~= 0 then
        if on_done then
          on_done(false)
        end
        return
      end
      vim.schedule(function()
        vim.fn.jobstart(fd_cmd_dirs, {
          stdout_buffered = true,
          on_stdout = function(_, data)
           if data then
              for _, line in ipairs(data) do
                if line ~= "" then
                  table.insert(all_found_dirs, line)
                end
              end
            end
          end,
          on_exit = function(_, dirs_code)
            if dirs_code ~= 0 then if on_done then on_done(false) end; return end
            
            progress:stage_update("file_scan", 1, "File scan complete. Classifying...")

            local refresh_roots = {}
            for _, c in ipairs(components_to_refresh) do
              refresh_roots[c.root_path] = true
            end
            
            local relevant_files = {}
            for _, file in ipairs(all_found_files) do
              for root_path in pairs(refresh_roots) do
                if file:find(root_path, 1, true) then
                  table.insert(relevant_files, file)
                  break
                end
              end
            end
            local relevant_dirs = {}
            for _, dir in ipairs(all_found_dirs) do
              for root_path in pairs(refresh_roots) do
                if dir:find(root_path, 1, true) then
                  table.insert(relevant_dirs, dir)
                  break
                end
              end
            end

            local files_by_component = {}
            for _, comp_data in pairs(all_components_data) do
              files_by_component[comp_data.name] = {
                files = { uproject={}, uplugin={}, source={}, config={}, shader={}, content={}, programs={}, other={} },
                dirs = { uproject={}, uplugin={}, source={}, config={}, shader={}, content={}, programs={}, other={} },
              }
            end
            
            local sorted_components = vim.tbl_values(all_components_data)
            table.sort(sorted_components, function(a,b) return #a.root_path > #b.root_path end)

            for _, file in ipairs(relevant_files) do
              for _, comp_data in ipairs(sorted_components) do
                if file:find(comp_data.root_path, 1, true) then
                  local category = core_utils.categorize_path(file)
                  table.insert(files_by_component[comp_data.name].files[category], file)
                  break
                end
              end
            end
            for _, dir in ipairs(relevant_dirs) do
              for _, comp_data in ipairs(sorted_components) do
                if dir:find(comp_data.root_path, 1, true) then
                  local category = core_utils.categorize_path(dir)
                  table.insert(files_by_component[comp_data.name].dirs[category], dir)
                  break
                end
              end
            end
            
            progress:stage_define("header_analysis", #relevant_files)
            local headers_to_parse = {}
            for _, file in ipairs(relevant_files) do
              -- 元のコード: if file:match("%.h$") then table.insert(headers_to_parse, file) end

              -- 修正後のコード: NoExportTypes.h を除外する条件を追加
              if file:match("%.h$") and not file:find("NoExportTypes.h", 1, true) then
                table.insert(headers_to_parse, file)
              end
            end
            
            -- ▼▼▼ 修正箇所 ▼▼▼
            local all_existing_header_details = {}
            for _, component in ipairs(components_to_refresh) do
                local existing_cache = files_cache_manager.load_component_cache(component)
                -- existing_cacheがnilでないこと、かつheader_detailsテーブルが存在することを確認
                if existing_cache and existing_cache.header_details then
                    for file_path, details in pairs(existing_cache.header_details) do
                        all_existing_header_details[file_path] = details
                    end
                end
            end

            class_parser.parse_headers_async(all_existing_header_details, headers_to_parse, progress, function(ok, header_details_by_file)
            -- ▲▲▲ ここまで ▲▲▲
              
              progress:stage_define("cache_save", #components_to_refresh)
              local saved_count = 0
              for _, component_to_save in ipairs(components_to_refresh) do
                saved_count = saved_count + 1
                progress:stage_update("cache_save", saved_count, ("Saving: %s [%d/%d]"):format(component_to_save.display_name, saved_count, #components_to_refresh))

                local component_files_data = files_by_component[component_to_save.name]
                if component_files_data then
                  local component_header_details = {}
                  if ok and header_details_by_file then
                    for _, file in ipairs(component_files_data.files.source) do
                      if header_details_by_file[file] then component_header_details[file] = header_details_by_file[file] end
                    end
                  end
                  local data_to_save = {
                    files = component_files_data.files,
                    directories = component_files_data.dirs,
                    header_details = component_header_details,
                  }
                  files_cache_manager.save_component_cache(component_to_save, data_to_save)
                end
              end
              progress:stage_update("cache_save", saved_count, "All file caches saved.")
              if on_done then on_done(true) end
            end)
          end,
        })
      end)
    end,
  })
end



function M.update_single_module_cache(module_name, on_complete)
  local log = uep_log.get()
  
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then if on_complete then on_complete(false) end; return end
    
    local module_meta = maps.all_modules_map[module_name]
    if not module_meta or not module_meta.module_root then
      log.error("Cannot update module '%s': not found in cache.", module_name)
      if on_complete then on_complete(false) end; return
    end
    
    local component_name = maps.module_to_component_name[module_name]
    local component_meta = maps.all_components_map[component_name]
    if not component_meta then
      log.error("Cannot update module '%s': its component '%s' not found.", module_name, component_name)
      if on_complete then on_complete(false) end; return
    end
    
    log.info("Starting lightweight refresh for module '%s' (Component: '%s')", module_name, component_meta.display_name)
    
    local conf = uep_config.get()
    local progress, _ = unl_progress.create_for_refresh(conf, {
      title = ("UEP: Updating %s..."):format(module_name),
      client_name = "UEP.LightweightRefresh"
    })
    progress:open()

    -- ★ 1. 共通ヘルパーを使ってfdコマンドを生成
    local fd_cmd_files = M.create_fd_command({ module_meta.module_root }, "f")
    local fd_cmd_dirs = M.create_fd_command({ module_meta.module_root }, "d")
    local new_files = {}
    local new_dirs = {}

    -- ★ 2. ファイルとディレクトリを順番にスキャンする
    vim.fn.jobstart(fd_cmd_files, {
      stdout_buffered = true,
      on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(new_files, line) end end end end,
      on_exit = function(_, files_code)
        if files_code ~= 0 then progress:finish(false); if on_complete then on_complete(false) end; return end
        
        vim.schedule(function()
          vim.fn.jobstart(fd_cmd_dirs, {
            stdout_buffered = true,
            on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(new_dirs, line) end end end end,
            on_exit = function(_, dirs_code)
              if dirs_code ~= 0 then progress:finish(false); if on_complete then on_complete(false) end; return end
              
              -- ★ 3. これ以降の更新ロジックはほぼ同じ
              local component_cache = files_cache_manager.load_component_cache(component_meta) or { files = {}, directories = {}, header_details = {} }
              
              for cat, file_list in pairs(component_cache.files) do
                component_cache.files[cat] = vim.tbl_filter(function(path) return not path:find(module_meta.module_root, 1, true) end, file_list)
              end
              for cat, dir_list in pairs(component_cache.directories) do
                component_cache.directories[cat] = vim.tbl_filter(function(path) return not path:find(module_meta.module_root, 1, true) end, dir_list)
              end
              for file_path, _ in pairs(component_cache.header_details) do
                if file_path:find(module_meta.module_root, 1, true) then component_cache.header_details[file_path] = nil end
              end

              local headers_to_parse = {}
              for _, path in ipairs(new_files) do
                local cat = core_utils.categorize_path(path)
                component_cache.files[cat] = component_cache.files[cat] or {}
                table.insert(component_cache.files[cat], path)
                if path:match('%.h$') then
                  table.insert(headers_to_parse, path)
                end
              end
              for _, path in ipairs(new_dirs) do
                local cat = core_utils.categorize_path(path)
                component_cache.directories[cat] = component_cache.directories[cat] or {}
                table.insert(component_cache.directories[cat], path)
              end


              class_parser.parse_headers_async(component_cache.header_details, headers_to_parse, progress, function(ok, new_header_details)
                if ok then
                  for file_path, details in pairs(new_header_details) do
                      component_cache.header_details[file_path] = details
                  end
                  files_cache_manager.save_component_cache(component_meta, component_cache)
                  log.info("Lightweight refresh for module '%s' complete.", module_name)
                  progress:finish(true)
                  if on_complete then on_complete(true) end
                else
                  log.error("Failed to parse headers during lightweight refresh.")
                  progress:finish(false)
                  if on_complete then on_complete(false) end
                end
              end)
            end,
          })
        end)
      end,
    })
  end)
end
return M
