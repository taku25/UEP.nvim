-- lua/UEP/cmd/clean_intermediate.lua
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")
local fs = require("vim.fs")
local uep_config = require("UEP.config")
local unl_progress = require("UNL.backend.progress")

local M = {}

-- 削除コマンドをOSに合わせて生成
local function get_delete_cmd(path)
  if vim.fn.has("win32") == 1 then
    return string.format('if exist "%s" rd /s /q "%s"', path, path)
  else
    return string.format('rm -rf "%s"', path)
  end
end

-- 削除実行 (非同期)
local function execute_deletion(paths, progress)
  local log = uep_log.get()
  local total = #paths
  local completed = 0
  local errors = {}

  progress:stage_define("delete", total)

  local function check_finish()
    if completed == total then
      if #errors > 0 then
        log.error("Intermediate cleanup finished with errors:\n%s", table.concat(errors, "\n"))
        vim.notify("Cleanup finished with errors. Check log.", vim.log.levels.ERROR)
        progress:finish(false)
      else
        log.info("Successfully removed %d Intermediate folders.", total)
        vim.notify("Intermediate folders cleaned.", vim.log.levels.INFO)
        progress:finish(true)
      end
    end
  end

  for _, path in ipairs(paths) do
    local cmd_str = get_delete_cmd(path)
    -- Windowsの場合は cmd.exe 経由、それ以外は直接実行
    local cmd = vim.fn.has("win32") == 1 and { "cmd.exe", "/c", cmd_str } or { "sh", "-c", cmd_str }

    vim.fn.jobstart(cmd, {
      on_exit = function(_, code)
        completed = completed + 1
        if code ~= 0 then
          table.insert(errors, "Failed to delete: " .. path)
        else
          log.info("Deleted: %s", path)
        end
        progress:stage_update("delete", completed, string.format("Deleted [%d/%d]: %s", completed, total, vim.fn.fnamemodify(path, ":t")))
        check_finish()
      end
    })
  end
end

-- Pluginsフォルダ内のIntermediateを検索
local function scan_plugins_intermediate(project_root, callback)
  local plugins_dir = fs.joinpath(project_root, "Plugins")
  
  -- ディレクトリがない場合は即座に空リストを返して終了
  if vim.fn.isdirectory(plugins_dir) == 0 then
    callback({})
    return
  end

  -- fdコマンドを使って Plugins 以下の Intermediate ディレクトリを検索
  local cmd = { "fd", "-t", "d", "-H", "-I", "--glob", "Intermediate", "--absolute-path", ".", plugins_dir }
  
  local found = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(found, line) end
        end
      end
    end,
    on_exit = function()
      callback(found)
    end
  })
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()
  
  local scope = (opts.scope or "project"):lower()
  if scope ~= "project" and scope ~= "engine" and scope ~= "all" then
    log.warn("Invalid scope '%s'. Defaulting to 'project'.", scope)
    scope = "project"
  end

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then return log.error("Failed to get project info.") end

    local paths_to_delete = {}
    local project_root = maps.project_root
    local engine_root = maps.engine_root

    -- ロック機構 (初期値1)
    local pending_operations = 1

    local function proceed_with_deletion()
      if #paths_to_delete == 0 then
        return vim.notify("No Intermediate folders found to clean.", vim.log.levels.INFO)
      end

      -- ★変更: GUI制限に合わせて最大10行まで表示
      local display_limit = 10 
      local msg_lines = { "The following folders will be PERMANENTLY DELETED:" }
      
      for i, path in ipairs(paths_to_delete) do
        if i <= display_limit then
          local rel_path = vim.fn.fnamemodify(path, ":~:.")
          table.insert(msg_lines, " - " .. rel_path)
        end
      end

      if #paths_to_delete > display_limit then
        table.insert(msg_lines, string.format("... and %d more (Total: %d)", #paths_to_delete - display_limit, #paths_to_delete))
      else
        table.insert(msg_lines, string.format("(Total: %d)", #paths_to_delete))
      end

      table.insert(msg_lines, "Are you sure you want to proceed?")
      
      local choice = vim.fn.confirm(table.concat(msg_lines, "\n"), "&Yes\n&No", 2)
      
      if choice ~= 1 then
        return log.info("Intermediate cleanup cancelled.")
      end

      local conf = uep_config.get()
      local progress, _ = unl_progress.create_for_refresh(conf, {
        title = "Cleaning Intermediate...",
        client_name = "UEP.Clean",
        weights = { delete = 1.0 }
      })
      progress:open()
      
      execute_deletion(paths_to_delete, progress)
    end

    local function check_done()
      if pending_operations == 0 then
        proceed_with_deletion()
      end
    end

    -- 1. Project Root Intermediate
    if (scope == "project" or scope == "all") and project_root then
      local p_inter = fs.joinpath(project_root, "Intermediate")
      if vim.fn.isdirectory(p_inter) == 1 then
        table.insert(paths_to_delete, p_inter)
      end

      -- 2. Project Plugins Intermediate (Async)
      pending_operations = pending_operations + 1
      scan_plugins_intermediate(project_root, function(plugin_paths)
        for _, p in ipairs(plugin_paths) do
          table.insert(paths_to_delete, p)
        end
        pending_operations = pending_operations - 1
        check_done()
      end)
    end

    -- 3. Engine Root Intermediate
    if (scope == "engine" or scope == "all") and engine_root then
      local e_inter = fs.joinpath(engine_root, "Engine", "Intermediate")
      if vim.fn.isdirectory(e_inter) == 1 then
        table.insert(paths_to_delete, e_inter)
      end
    end

    -- ロック解除
    pending_operations = pending_operations - 1
    check_done()

  end)
end

return M
