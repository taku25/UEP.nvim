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
    local all_components = maps.all_components_map

    -- 1. Project & Plugins Intermediate
    if (scope == "project" or scope == "all") and project_root then
      -- プロジェクトルートのIntermediate (Game)
      local p_inter = fs.joinpath(project_root, "Intermediate")
      if vim.fn.isdirectory(p_inter) == 1 then
        table.insert(paths_to_delete, p_inter)
      end

      -- コンポーネント(Plugin等)のIntermediate
      -- DBから取得したコンポーネント情報を使用
      for _, comp in pairs(all_components) do
        -- プロジェクト内のコンポーネントかチェック (パスで判定)
        -- normalizeして比較するのが安全
        local comp_root = comp.root_path:gsub("\\", "/")
        local proj_root_norm = project_root:gsub("\\", "/")
        
        -- プロジェクトルート以下のコンポーネント、かつプロジェクトルートそのものではない場合
        -- (プロジェクトルートそのものは上で追加済み)
        if comp_root:find(proj_root_norm, 1, true) and comp_root ~= proj_root_norm then
           local inter = fs.joinpath(comp.root_path, "Intermediate")
           if vim.fn.isdirectory(inter) == 1 then
             table.insert(paths_to_delete, inter)
           end
        end
      end
    end

    -- 2. Engine Root Intermediate
    if (scope == "engine" or scope == "all") and engine_root then
      local e_inter = fs.joinpath(engine_root, "Engine", "Intermediate")
      if vim.fn.isdirectory(e_inter) == 1 then
        table.insert(paths_to_delete, e_inter)
      end
    end

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
  end)
end

return M
