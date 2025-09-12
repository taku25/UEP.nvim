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

---
-- 単一のプロジェクトタイプ (Game or Engine) を更新するメインの処理フロー
local function process_single_project_type(root_path, type, force_regenerate, engine_cache, progress, on_complete)
  local log = uep_log.get()
  log.info("Processing '%s' project at: %s", type, root_path)

  -- 1. 分析官にプロジェクト分析を依頼
  refresh_project.analyze(root_path, type, engine_cache, progress, function(ok, new_data)
    if not ok then on_complete(false, nil); return end
    if not new_data then on_complete(true, project_cache.load(root_path)); return end

    local old_data = project_cache.load(root_path)
    local needs_project_update = force_regenerate or not old_data or old_data.generation ~= new_data.generation
    local data_for_files_cache = needs_project_update and new_data or old_data

    if needs_project_update then
      log.info("'%s' modules have changed. Regenerating project cache...", type)
      progress:stage_define("save_project_cache", 1)
      progress:stage_update("save_project_cache", 0, "Saving project cache...")
      project_cache.save(root_path, type, new_data)
      progress:stage_update("save_project_cache", 1, "Project cache saved.")
      if type == "Game" and new_data.uproject_path then
        projects_cache.add_or_update({ root = root_path, uproject_path = new_data.uproject_path, engine_root_path = new_data.link_engine_cache_root })
      end
    else
      log.info("'%s' modules are up to date.", type)
    end

    -- 2. 情報収集官にファイルキャッシュ作成を依頼
    refresh_files.create_cache(type, data_for_files_cache, engine_cache, progress, function(file_cache_ok)
      if not file_cache_ok then on_complete(false, data_for_files_cache); return end

      -- 3. Gameプロジェクトの場合は、ヘッダー解析を行う (このロジックは司令官が持つ)
      if type == "Game" then
        progress:stage_define("parse_headers", 1)
        progress:stage_update("parse_headers", 0, "Analyzing C++ headers...")
        local target_modules = {}
        local all_modules_meta = vim.tbl_deep_extend("force", engine_cache and engine_cache.modules or {}, data_for_files_cache.modules)
        for name, meta in pairs(data_for_files_cache.modules) do
          if meta.category == "Game" then
            target_modules[name] = true
            if meta.deep_dependencies then
              for _, dep_name in ipairs(meta.deep_dependencies) do target_modules[dep_name] = true end
            end
          end
        end
        local files_cache = files_disk_cache.load(root_path)
        local engine_files_cache = engine_cache and files_disk_cache.load(engine_cache.root) or nil
        local headers_to_parse = {}
        if files_cache and files_cache.files_by_module then
          for module_name, _ in pairs(target_modules) do
            local file_list = files_cache.files_by_module[module_name] or (engine_files_cache and engine_files_cache.files_by_module[module_name])
            if file_list then
              for _, file_path in ipairs(file_list) do if file_path:match("%.h$") then table.insert(headers_to_parse, file_path) end end
            end
          end
        end
        if #headers_to_parse > 0 then
          class_parser.parse_headers_async(root_path, headers_to_parse, progress, function(parse_ok, header_details)
            if parse_ok then
              local final_files_cache = files_disk_cache.load(root_path) or {}
              final_files_cache.header_details = header_details
              files_disk_cache.save(root_path, final_files_cache)
              progress:stage_update("parse_headers", 1, "Header analysis complete.")
            else
              progress:stage_update("parse_headers", 1, "Header analysis failed.", { error = true })
            end
            on_complete(true, data_for_files_cache)
          end)
        else
          on_complete(true, data_for_files_cache)
        end
      else
        on_complete(true, data_for_files_cache)
      end
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
