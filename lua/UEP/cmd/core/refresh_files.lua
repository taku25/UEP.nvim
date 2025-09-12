-- lua/UEP/core/refresh_files.lua (情報収集官)

local uep_config = require("UEP.config")
local files_disk_cache = require("UEP.cache.files")
local uep_log = require("UEP.logger")
local project_cache = require("UEP.cache.project")
local unl_progress = require("UNL.backend.progress")

local M = {}

-------------------------------------------------
-- Helper Functions
-------------------------------------------------

local function find_owner_module(file_path, sorted_modules)
  for _, meta in ipairs(sorted_modules) do
    if file_path:find(meta.root, 1, true) then
      return meta.name
    end
  end
  return nil
end

local function create_fd_command_for_files(search_paths)
  local conf = uep_config.get()
  local extensions = conf.files_extensions or { "cpp", "h", "hpp", "inl", "ini", "cs" }
  local full_path_regex = ".*(Source|Config|Plugins).*.(" .. table.concat(extensions, "|") .. ")$"
  local excludes = { "Intermediate", "Binaries", "Saved" }

  local fd_cmd = {
    "fd", "--regex", full_path_regex, "--full-path", "--type", "f",
    "--path-separator", "/", "--absolute-path",
  }
  for _, dir in ipairs(excludes) do table.insert(fd_cmd, "--exclude"); table.insert(fd_cmd, dir) end
  if search_paths and type(search_paths) == "table" then
    vim.list_extend(fd_cmd, search_paths)
  end
  return fd_cmd
end

local function create_fd_command_for_dirs(search_paths)
  local excludes = { "Intermediate", "Binaries", "Saved", ".git", ".vs" }
  local fd_cmd = {
    "fd", "--type", "d", "--full-path", "--absolute-path",
  }
  for _, dir in ipairs(excludes) do table.insert(fd_cmd, "--exclude"); table.insert(fd_cmd, dir) end
  if search_paths and type(search_paths) == "table" then
    vim.list_extend(fd_cmd, search_paths)
  end
  return fd_cmd
end

-------------------------------------------------
-- Public APIs
-------------------------------------------------

---
-- ファイルとディレクトリのキャッシュを作成する
function M.create_cache(scope, project_data, engine_data, progress, on_all_done)
  progress:stage_define("create_file_cache", 1)
  progress:stage_update("create_file_cache", 0, "Scanning project files for " .. scope .. "...")

  local search_path = project_data.root
  local fd_cmd_files = create_fd_command_for_files({ search_path })
  local fd_cmd_dirs = create_fd_command_for_dirs({ search_path })
  local found_files = {}
  local found_dirs = {}

  vim.fn.jobstart(fd_cmd_files, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(found_files, line) end end end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        progress:stage_update("create_file_cache", 1, "Failed to list files.", { error = true })
        if on_all_done then on_all_done(false) end
        return
      end
      
      -- ファイル検索が完了したら、次にディレクトリを検索
      vim.fn.jobstart(fd_cmd_dirs, {
        stdout_buffered = true,
        on_stdout = function(_, data)
          if data then for _, line in ipairs(data) do if line ~= "" then table.insert(found_dirs, line) end end end
        end,
        on_exit = function(_, dir_code)
          if dir_code ~= 0 then
            progress:stage_update("create_file_cache", 1, "Failed to list directories.", { error = true })
            if on_all_done then on_all_done(false) end
            return
          end

          local co = coroutine.create(function()
            local all_files_by_module = {}
            local all_modules_meta = vim.tbl_deep_extend("force", {}, engine_data and engine_data.modules or {}, project_data.modules)
            local sorted_modules = {}
            for name, meta in pairs(all_modules_meta) do
              if meta.module_root then
                table.insert(sorted_modules, { name = name, root = meta.module_root .. "/" })
              end
            end
            table.sort(sorted_modules, function(a, b) return #a.root > #b.root end)
            
            local total_files = #found_files
            if total_files > 0 then
              for i = 1, total_files do
                local file_path = found_files[i]
                local owner = find_owner_module(file_path, sorted_modules)
                if owner then
                  if not all_files_by_module[owner] then all_files_by_module[owner] = {} end
                  table.insert(all_files_by_module[owner], file_path)
                end
                if i % 500 == 0 then
                  progress:stage_update("create_file_cache", i / total_files, ("Processing files (%d/%d)..."):format(i, total_files))
                  coroutine.yield()
                end
              end
            end

            local cache_to_save = {
              category = scope,
              generation = project_data.generation,
              owner_project_root = project_data.root,
              files_by_module = all_files_by_module,
              all_directories = found_dirs,
            }
            files_disk_cache.save(project_data.root, cache_to_save)
            progress:stage_update("create_file_cache", 1, "File cache for " .. scope .. " created.")
            if on_all_done then on_all_done(true) end
          end)

          local function resume_handler()
            local status, err = coroutine.resume(co)
            if not status then
              uep_log.get().error("Error in file cache coroutine: %s", tostring(err))
              if on_all_done then on_all_done(false) end
              return
            end
            if coroutine.status(co) ~= "dead" then
              vim.defer_fn(resume_handler, 1)
            end
          end
          resume_handler()
        end
      })
    end
  })
end


---
-- 単一のモジュールのみを対象に、ファイルキャッシュを軽量に更新する
function M.update_single_module_cache(module_name, on_complete)
  local game_data = project_cache.load(vim.loop.cwd())

  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, { title = "UEP: Module Files...", client_name = "UEP" })
  progress:open()

  if not game_data then
    if on_complete then
      on_complete(false)
    end
    progress:finish(false)
    return
  end
  local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil

  local all_modules = vim.tbl_deep_extend("force", {}, engine_data and engine_data.modules or {}, game_data.modules or {})
  local target_module = all_modules[module_name]
  if not (target_module and target_module.module_root) then
    uep_log.get().error("Cannot update file cache: Module '%s' not found.", module_name)
    if on_complete then
      on_complete(false)
    end
    progress:finish(false)
    return
  end
  
  local fd_cmd_files = create_fd_command_for_files({ target_module.module_root })
  local found_files = {}
  vim.fn.jobstart(fd_cmd_files, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(found_files, line) end end end end,
    on_exit = function(_, code)
      if code ~= 0 then
        if on_complete then
          on_complete(false)
        end
        progress:finish(false)
        return
      end

      local target_project_data = (game_data.modules and game_data.modules[module_name]) and game_data or engine_data
      if not target_project_data then
        if on_complete then
          on_complete(false)
        end
        progress:finish(false)
        return
      end

      local full_disk_cache = files_disk_cache.load(target_project_data.root) or {}
      full_disk_cache.files_by_module = full_disk_cache.files_by_module or {}
      full_disk_cache.files_by_module[module_name] = found_files
      full_disk_cache.generation = target_project_data.generation

      files_disk_cache.save(target_project_data.root, full_disk_cache)

      uep_log.get().info("Lightweight file cache update for module '%s' complete.", module_name)
      if on_complete then
        on_complete(true)
      end
      progress:finish(true)
    end
  })
end

return M
