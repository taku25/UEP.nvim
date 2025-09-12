-- lua/UEP/cmd/refresh.lua (司令官)

local unl_finder = require("UNL.finder")
local uep_config = require("UEP.config")
local unl_progress = require("UNL.backend.progress")
local project_cache = require("UEP.cache.project")
local projects_cache = require("UEP.cache.projects")
local uep_log = require("UEP.logger")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")
local class_parser = require("UEP.parser.class")
local files_disk_cache = require("UEP.cache.files")

-- ★★★ 新しいcoreモジュールをrequireする ★★★
local refresh_project = require("UEP.cmd.core.refresh_project")
local refresh_files = require("UEP.cmd.core.refresh_files")

local M = {}

-- 単一のプロジェクトタイプ (Game or Engine) を更新するメインの処理フロー。
-- 責務をcoreモジュールに完全に移譲した、スリムで高レベルな司令官。
-- @param root_path string
-- @param type "Game" | "Engine"
-- @param force_regenerate boolean
-- @param engine_cache table | nil
-- @param progress table
-- @param on_complete fun(ok: boolean, updated_data: table|nil)
local function process_single_project_type(root_path, type, force_regenerate, engine_cache, progress, on_complete)
  local log = uep_log.get()
  refresh_project.analyze(root_path, type, engine_cache, progress, function(analyze_ok, new_data)
    if not analyze_ok or not new_data then
      on_complete(false, nil)
      return
    end
    local old_data = project_cache.load(root_path)
    local needs_project_update = force_regenerate or not old_data or old_data.generation ~= new_data.generation
    local data_for_files_cache = needs_project_update and new_data or old_data
    if needs_project_update then
      project_cache.save(root_path, type, new_data)
      if type == "Game" and new_data.uproject_path then
        projects_cache.add_or_update({ root = root_path, uproject_path = new_data.uproject_path, engine_root_path = new_data.link_engine_cache_root })
      end
    end
    -- ★★★ 情報収集官に、ファイル、ディレクトリ、ヘッダー解析の全てを完全に一任する ★★★
    refresh_files.create_cache(type, data_for_files_cache, engine_cache, progress, function(file_cache_ok)
      on_complete(file_cache_ok, data_for_files_cache)
    end)
  end)
end

---
-- 公開API: コマンドのエントリーポイント
function M.execute(opts, on_complete)
  opts = opts or {}
  local force_regenerate = opts.has_bang or false
  local type_arg = opts.type or "Game"
  local log = uep_log.get()

  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then if on_complete then on_complete(false) end; return log.error("Not in an Unreal Engine project directory.") end
  
  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject, {}) or nil
  if not engine_root then if on_complete then on_complete(false) end; return log.error("Could not find engine root.") end

  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, { title = "UEP: Refreshing project...", client_name = "UEP" })
  progress:open()

  local function finish_all(ok)
    progress:finish(ok)
    unl_events.publish(unl_types.ON_AFTER_REFRESH_COMPLETED, { status = ok and "success" or "failed" })
    if on_complete then on_complete(ok) end
  end

  process_single_project_type(engine_root, "Engine", force_regenerate, nil, progress, function(engine_ok, updated_engine_data)
    if not engine_ok then return finish_all(false) end
    if type_arg:lower() == "engine" then return finish_all(true) end

    process_single_project_type(project_root, "Game", force_regenerate, updated_engine_data, progress, function(game_ok, _)
      finish_all(game_ok)
    end)
  end)
end

---
-- 公開API: 軽量リフレッシュ
function M.update_file_cache_for_single_module(module_name, on_complete, passthrough_payload)
  -- ★★★ 責務を情報収集官に完全に委譲する ★★★
  refresh_files.update_single_module_cache(module_name, function(ok)
    if on_complete then on_complete(ok, passthrough_payload) end
  end)
end

return M
