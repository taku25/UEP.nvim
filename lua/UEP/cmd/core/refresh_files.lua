-- lua/UEP/cmd/core/refresh_files.lua (第三世代・究極の精密攻撃部隊・最終完成版)

local class_parser = require("UEP.parser.class")
local uep_config = require("UEP.config")
local files_cache_manager = require("UEP.cache.files")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------
local function create_fd_command(base_paths, type_flag)
  local conf = uep_config.get()
  local extensions = conf.include_extensions or { "cpp", "h", "hpp", "inl", "ini", "cs", "usf", "ush" }
  local include_dirs = conf.include_directory or { "Source", "Config", "Plugins", "Shaders", "Programs" }
  local exclude_dirs = conf.excludes_directory or { "Intermediate", "Binaries", "Saved" }
  local dir_pattern = "(" .. table.concat(include_dirs, "|") .. ")"
  local final_regex
  if type_flag == "f" then
    local ext_pattern = "(" .. table.concat(extensions, "|") .. ")"
    final_regex = ".*[\\\\/]" .. dir_pattern .. "[\\\\/].*\\." .. ext_pattern .. "$"
  else -- "d"
    final_regex = ".*[\\\\/]" .. dir_pattern .. "[\\\\/]?.*"
  end
  local fd_cmd = { "fd", "--regex", final_regex, "--full-path", "--type", type_flag, "--path-separator", "/" }
  for _, dir in ipairs(exclude_dirs) do table.insert(fd_cmd, "--exclude"); table.insert(fd_cmd, dir) end
  vim.list_extend(fd_cmd, base_paths)
  return fd_cmd
end

local function categorize_path(path)
  if path:find("/Shaders/", 1, true) or path:match("/Shaders$") then return "shader" end
  if path:find("/Config/", 1, true) or path:match("/Config$") then return "config" end
  if path:find("/Source/", 1, true) or path:match("/Source$") then return "source" end
  if path:find("/Programs/", 1, true) or path:match("/Programs$") then return "programs" end
  if path:find("/Content/", 1, true) or path:match("/Content$") then return "content" end
  if path:find("/Plugins/", 1, true) then return "source" end
  return "other"
end

-------------------------------------------------
-- 新しいAPI
-------------------------------------------------
function M.create_component_caches_for(components_to_refresh, all_components_data, game_root, engine_root, progress, on_done)
  progress:stage_define("file_scan", 0.1)
  progress:stage_define("header_analysis", 0.4)
  progress:stage_define("cache_save", 0.5)
  progress:stage_update("file_scan", 0, ("Scanning files for %d components..."):format(#components_to_refresh))

  if #components_to_refresh == 0 then
      uep_log.get().info("No components need file scanning.")
      if on_done then on_done(true) end
      return
  end

  -- ▼▼▼ これが最後の、そして最も重要な修正点です ▼▼▼
  local top_level_search_paths = { game_root, engine_root }
  -- ▲▲▲ ここまで ▲▲▲
  
  local fd_cmd_files = create_fd_command(top_level_search_paths, "f")
  local fd_cmd_dirs = create_fd_command(top_level_search_paths, "d")

  local all_found_files = {}
  local all_found_dirs = {}

  vim.fn.jobstart(fd_cmd_files, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_found_files, line) end end end end,
    on_exit = function(_, files_code)
      if files_code ~= 0 then if on_done then on_done(false) end; return end
      vim.schedule(function()
        vim.fn.jobstart(fd_cmd_dirs, {
          stdout_buffered = true,
          on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_found_dirs, line) end end end end,
          on_exit = function(_, dirs_code)
            if dirs_code ~= 0 then if on_done then on_done(false) end; return end
            
            progress:stage_update("file_scan", 1, "File scan complete. Classifying...")

            local refresh_roots = {}
            for _, c in ipairs(components_to_refresh) do refresh_roots[c.root_path] = true end
            
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
              files_by_component[comp_data.name] = { files = { source={}, config={}, shader={}, content={}, programs={}, other={} }, dirs = { source={}, config={}, shader={}, content={}, programs={}, other={} } }
            end
            
            local sorted_components = vim.tbl_values(all_components_data)
            table.sort(sorted_components, function(a,b) return #a.root_path > #b.root_path end)

            for _, file in ipairs(relevant_files) do
              for _, comp_data in ipairs(sorted_components) do
                if file:find(comp_data.root_path, 1, true) then
                  local category = categorize_path(file)
                  table.insert(files_by_component[comp_data.name].files[category], file)
                  break
                end
              end
            end
            for _, dir in ipairs(relevant_dirs) do
              for _, comp_data in ipairs(sorted_components) do
                if dir:find(comp_data.root_path, 1, true) then
                  local category = categorize_path(dir)
                  table.insert(files_by_component[comp_data.name].dirs[category], dir)
                  break
                end
              end
            end
            
            progress:stage_define("header_analysis", #relevant_files)
            local headers_to_parse = {}
            for _, file in ipairs(relevant_files) do if file:match("%.h$") then table.insert(headers_to_parse, file) end end
            
            class_parser.parse_headers_async({}, headers_to_parse, progress, function(ok, header_details_by_file)
              
              progress:stage_define("cache_save", #components_to_refresh)
              local saved_count = 0
              for _, component_to_save in ipairs(components_to_refresh) do
                saved_count = saved_count + 1
                progress:stage_update("cache_save", saved_count, ("Saving: %s"):format(component_to_save.display_name))

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

return M
