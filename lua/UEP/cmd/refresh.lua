-- lua/UEP/cmd/refresh.lua (構文エラー修正版)

local unl_finder        = require("UNL.finder")
local uep_config        = require("UEP.config")
local unl_progress      = require("UNL.backend.progress")
local unl_path          = require("UNL.path")
local fs                = require("vim.fs")
local unl_analyzer      = require("UNL.analyzer.build_cs")
local uep_graph         = require("UEP.graph")
local project_cache     = require("UEP.cache.project")
local projects_cache    = require("UEP.cache.projects")
local uep_log           = require("UEP.logger")
local files_disk_cache  = require("UEP.cache.files")
local unl_events        = require("UNL.event.events")
local unl_types         = require("UNL.event.types")
-- local class_parser      = require("UEP.parser.class") -- 新規作成するパーサーモジュール
local M = {}

-------------------------------------------------
-- Helper Functions (変更なし)
-------------------------------------------------
local function tbl_unique(list)
  local seen, result = {}, {}
  for _, v in ipairs(list) do if not seen[v] then seen[v] = true; table.insert(result, v) end end
  return result
end

local function find_owner_module(file_path, sorted_modules)
  for _, meta in ipairs(sorted_modules) do
    if file_path:find(meta.root, 1, true) then
      return meta.name
    end
  end
  return nil
end

local function create_fd_command(search_paths)
  local conf = uep_config.get()
  local extensions = conf.files_extensions or { "cpp", "h", "hpp", "inl", "ini", "cs" }
  local full_path_regex = ".*(Source|Config|Plugins).*.(" .. table.concat(extensions, "|") .. ")$"
  local excludes = { "Intermediate", "Binaries", "Saved" }

  local fd_cmd = {
    "fd",
    "--regex", full_path_regex,
    "--full-path",
    "--type", "f",
    "--path-separator", "/",
    "--absolute-path",
  }

  for _, dir in ipairs(excludes) do
    table.insert(fd_cmd, "--exclude")
    table.insert(fd_cmd, dir)
  end

  if search_paths and type(search_paths) == "table" then
    vim.list_extend(fd_cmd, search_paths)
  end

  return fd_cmd
end
local function build_fs_tree_from_flat_list(file_list, root_path)
  local root = {}
  for _, file_path in ipairs(file_list) do
    local current_level = root
    local relative_path = file_path:sub(#root_path + 2)
    local parts = vim.split(relative_path, "[/]")
    for i, part in ipairs(parts) do
      if not current_level[part] then current_level[part] = {} end
      current_level = current_level[part]
    end
  end
  local function table_to_nodes(tbl, current_path)
    local nodes = {}
    for name, content in pairs(tbl) do
      local new_path = fs.joinpath(current_path, name)
      local node_type = "file"
      local children_nodes = nil
      if next(content) then
        node_type = "directory"
        children_nodes = table_to_nodes(content, new_path)
      end
      table.insert(nodes, { id = new_path, name = name, path = new_path, type = node_type, children = children_nodes })
    end
    table.sort(nodes, function(a, b) return a.name < b.name end)
    return nodes
  end
  return table_to_nodes(root, root_path)
end

--- ファイルキャッシュ作成処理 (coroutineによるリファクタリング版)
-- @param scope string "Game" or "Engine"
-- @param project_data table
-- @param engine_data table|nil
-- @param progress table
-- @param on_all_done function(ok) 全ての処理が完了したときに呼ばれるコールバック
local function create_file_cache(scope, project_data, engine_data, progress, on_all_done)
  progress:stage_define("create_file_cache", 1)
  progress:stage_update("create_file_cache", 0, "Scanning project files for " .. scope .. "...")

  local search_path = project_data.root
  local fd_cmd = create_fd_command({ search_path })
  local found_files = {}

  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(found_files, line) end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        progress:stage_update("create_file_cache", 1, "Failed to list files.", { error = true })
        if on_all_done then on_all_done(false) end
        return
      end

      -- ★★★ ここからがcoroutineを使った新しい処理フロー ★★★
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
        local chunk_size = 500

        if total_files > 0 then
          for i = 1, total_files do
            local file_path = found_files[i]
            local owner = find_owner_module(file_path, sorted_modules)
            if owner then
              if not all_files_by_module[owner] then all_files_by_module[owner] = {} end
              table.insert(all_files_by_module[owner], file_path)
            end
            
            -- チャンクごとにUIに制御を返し、プログレスバーを更新する
            if i % chunk_size == 0 then
              progress:stage_update("create_file_cache", i / total_files, ("Processing files (%d/%d)..."):format(i, total_files))
              coroutine.yield() -- ここで処理を中断し、resume_handlerに制御を戻す
            end
          end
        end

        -- ループ完了後、最終的なキャッシュを作成して保存
        local cache_to_save = {
          category = scope,
          generation = project_data.generation,
          owner_project_root = project_data.root,
          files_by_module = all_files_by_module,
        }
        files_disk_cache.save(project_data.root, cache_to_save)
        progress:stage_update("create_file_cache", 1, "File cache for " .. scope .. " created.")
        
        -- 最後に完了コールバックを呼ぶ
        if on_all_done then on_all_done(true) end
      end)

      -- coroutineを実行するためのランナー
      local function resume_handler()
        local status, err = coroutine.resume(co)
        if not status then
          uep_log.get().error("Error in create_file_cache coroutine: %s", tostring(err))
          if on_all_done then on_all_done(false) end
          return
        end
        -- coroutineがまだ終了していなければ（yieldで中断された場合）、
        -- 次のUIティックで処理を再開するようスケジュールする
        if coroutine.status(co) ~= "dead" then
          vim.defer_fn(resume_handler, 0) -- 0ms or 1ms
        end
      end

      -- coroutineの実行を開始
      resume_handler()
    end
  })
end
--- モジュール解析とハッシュ計算を行うコアロジックを独立関数に
local function analyze_and_get_project_data(root_path, type, engine_cache, progress, on_complete)
  local search_paths
  if type == "Game" then
    search_paths = { fs.joinpath(root_path, "Source"), fs.joinpath(root_path, "Plugins") }
  else -- Engine
    search_paths = { fs.joinpath(root_path, "Engine", "Source"), fs.joinpath(root_path, "Engine", "Plugins") }
  end

  progress:stage_define("scan_modules", 1)
  progress:stage_update("scan_modules", 0, "Scanning for Build.cs files...")

  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "Build.cs", unpack(tbl_unique(search_paths)) }
  local build_cs_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(build_cs_files, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 or #build_cs_files == 0 then
        progress:stage_update("scan_modules", 1, "No modules found.")
        on_complete(true, nil) -- モジュールがなくてもエラーではない
        return
      end
      progress:stage_update("scan_modules", 1, ("Found %d modules."):format(#build_cs_files))

      local co = coroutine.create(function()
        progress:stage_define("parse_modules", #build_cs_files)
        local modules_meta = {}
        for i, raw_path in ipairs(build_cs_files) do
          local build_cs_path = unl_path.normalize(raw_path)
          local module_name = vim.fn.fnamemodify(build_cs_path, ":h:t")
          progress:stage_update("parse_modules", i, "Parsing: " .. module_name)
          local module_root = vim.fn.fnamemodify(build_cs_path, ":h")
          local location = build_cs_path:find("/Plugins/", 1, true) and "in_plugins" or (build_cs_path:find("/Source/", 1, true) and "in_source" or "unknown")
          local dependencies = unl_analyzer.parse(build_cs_path)
          modules_meta[module_name] = { name = module_name, path = build_cs_path, module_root = module_root, category = type, location = location, dependencies = dependencies }
          if i % 5 == 0 then coroutine.yield() end
        end
        progress:stage_update("parse_modules", #build_cs_files, "All modules parsed.")
        coroutine.yield()

        progress:stage_define("resolve_deps", 1)
        progress:stage_update("resolve_deps", 0, "Building dependency graph...")
        local modules_with_resolved_deps, _ = uep_graph.resolve_all_dependencies(modules_meta, engine_cache and engine_cache.modules or nil)
        progress:stage_update("resolve_deps", 1, "Dependency resolution complete.")
        coroutine.yield()

        if not modules_with_resolved_deps then
          on_complete(false, nil)
          return
        end

        local content_to_hash = vim.json.encode(modules_with_resolved_deps)
        local data_hash = vim.fn.sha256(content_to_hash)
        local new_data = { generation = data_hash, modules = modules_with_resolved_deps, root = root_path }

        if type == "Game" then
          new_data.uproject_path = unl_finder.project.find_project_file(root_path)
          new_data.link_engine_cache_root = engine_cache and engine_cache.root or nil
        end
        on_complete(true, new_data)
      end)

      local function resume_handler()
        local status, _ = coroutine.resume(co)
        if not status then
          on_complete(false, nil)
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


--- 単一のプロジェクトタイプ (Game or Engine) を更新するメインの処理フロー
local function process_single_project_type(root_path, type, force_regenerate, engine_cache, progress, on_complete)
  local log = uep_log.get()
  log.info("Processing '%s' project at: %s", type, root_path)

  analyze_and_get_project_data(root_path, type, engine_cache, progress, function(ok, new_data)
    if not ok then on_complete(false, nil); return end
    if not new_data then -- モジュールが一つもなかった場合
      on_complete(true, project_cache.load(root_path))
      return
    end

    local old_data = project_cache.load(root_path)
    local needs_project_update = force_regenerate or not old_data or old_data.generation ~= new_data.generation

    local data_for_files_cache -- filesキャッシュ作成に使う最終的なプロジェクトデータ

    if needs_project_update then
      log.info("'%s' modules have changed. Regenerating project cache...", type)
      progress:stage_define("save_project_cache", 1)
      progress:stage_update("save_project_cache", 0, "Saving project cache...")
      project_cache.save(root_path, type, new_data)
      progress:stage_update("save_project_cache", 1, "Project cache saved.")

      if type == "Game" and new_data.uproject_path then
        projects_cache.add_or_update({ root = root_path, uproject_path = new_data.uproject_path, engine_root_path = new_data.link_engine_cache_root })
      end
      data_for_files_cache = new_data -- 新しいデータを使う
    else
      log.info("'%s' modules are up to date. Skipping project cache save.", type, new_data.generation:sub(1, 7))
      data_for_files_cache = old_data -- 既存のデータを使う
    end

    -- ★★★ filesキャッシュの作成は、projectキャッシュの更新有無に関わらず常に実行する ★★★
    create_file_cache(type, data_for_files_cache, engine_cache, progress, function(file_cache_ok)
      if not file_cache_ok then
        on_complete(false, data_for_files_cache)
        return
      end

      -- ▼▼▼ ここからが追加ブロック ▼▼▼
      -- Gameプロジェクトの深い依存関係モジュールのみを対象に、ヘッダー解析を行う
      if type == "Game" then
        local class_parser = require("UEP.parser.class")

        progress:stage_define("parse_headers", 1)
        progress:stage_update("parse_headers", 0, "Analyzing C++ headers...")

        -- 1. 解析対象モジュールを特定
        -- ▼▼▼ このブロックを修正します ▼▼▼

        -- 1. 解析対象モジュールを特定（カテゴリの縛りをなくす）
        local target_modules = {}

        -- GameとEngineの全モジュール情報を一時的にマージして、依存関係を辿れるようにする
        local all_modules_meta = vim.tbl_deep_extend("force", 
        engine_cache and engine_cache.modules or {}, 
        data_for_files_cache.modules)

        for name, meta in pairs(data_for_files_cache.modules) do
          -- Gameプロジェクトに属するモジュールは常に対象
          if meta.category == "Game" then
            target_modules[name] = true
            -- そのモジュールの深い依存関係をすべて追加する（Engineモジュールも含む！）
            if meta.deep_dependencies then
              for _, dep_name in ipairs(meta.deep_dependencies) do
                target_modules[dep_name] = true
              end
            end
          end
        end

        -- 2. ファイルキャッシュをロードし、解析対象のヘッダーファイルリストを作成
        -- (この部分のロジックは変更なし)
        local files_cache = files_disk_cache.load(root_path)
        -- Engine側のファイルキャッシュもロードする必要がある
        local engine_files_cache = engine_cache and files_disk_cache.load(engine_cache.root) or nil

        local headers_to_parse = {}
        if files_cache and files_cache.files_by_module then
          for module_name, _ in pairs(target_modules) do
            -- モジュールがGameキャッシュにあるか、Engineキャッシュにあるかを探してファイルリストを取得
            local file_list = files_cache.files_by_module[module_name] 
            or (engine_files_cache and engine_files_cache.files_by_module[module_name])

            if file_list then
              for _, file_path in ipairs(file_list) do
                if file_path:match("%.h$") then
                  table.insert(headers_to_parse, file_path)
                end
              end
            end
          end
        end

        -- 3. 新しいパーサーに処理を委譲
        if #headers_to_parse > 0 then
          -- 解析処理を非同期で実行し、完了したらコールバック
          class_parser.parse_headers_async(root_path, headers_to_parse, progress, function(ok, header_details)
            if ok then
              -- 既存のファイルキャッシュに詳細情報をマージして保存
              local final_files_cache = files_disk_cache.load(root_path) or {}
              final_files_cache.header_details = header_details
              files_disk_cache.save(root_path, final_files_cache)
              progress:stage_update("parse_headers", 1, "Header analysis complete.")
            else
              progress:stage_update("parse_headers", 1, "Header analysis failed.", { error = true })
            end
            -- 解析の成否に関わらず、refresh全体の完了コールバックを呼ぶ
            on_complete(true, data_for_files_cache)
          end)
        else
          -- 解析対象ファイルがない場合は、そのまま完了
          on_complete(true, data_for_files_cache)
        end
      else
        -- Engineプロジェクトの場合は何もしない
        on_complete(true, data_for_files_cache)
      end
      -- ▲▲▲ 追加ブロックここまで ▲▲▲
    end)
  end)
end

-------------------------------------------------
-- Public API (M.execute)
-------------------------------------------------

function M.execute(opts, on_complete)
  local force_regenerate = opts.has_bang or false
  local type_arg = opts.type or "Game" -- デフォルトはGame
  local log = uep_log.get()

  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    log.error("Not in an Unreal Engine project directory.")
    if on_complete then on_complete(false) end
    return
  end

  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject, {}) or nil

  if not engine_root then
    log.error("Could not find engine root.")
    if on_complete then on_complete(false) end
    return
  end

  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, { title = "UEP: Refreshing project...", client_name = "UEP" })
  progress:open()

  local function finish_all(ok)
    progress:finish(ok)
    unl_events.publish(unl_types.ON_AFTER_REFRESH_COMPLETED, { status = ok and "success" or "failed" })
    if on_complete then on_complete(ok) end
  end

  -- STEP 1: Engineを処理
  process_single_project_type(engine_root, "Engine", force_regenerate, nil, progress, function(engine_ok, updated_engine_data)
    if not engine_ok then
      log.error("Failed to process Engine cache.")
      finish_all(false)
      return
    end

    -- typeがEngineの場合はここで終了
    if type_arg:lower() == "engine" then
      log.info("Engine refresh complete.")
      finish_all(true)
      return
    end

    -- STEP 2: Gameを処理 (Engine処理が完了した後)
    process_single_project_type(project_root, "Game", force_regenerate, updated_engine_data, progress, function(game_ok, _)
      if not game_ok then
        log.error("Failed to process Game cache.")
        finish_all(false)
        return
      end
      log.info("Game and Engine refresh process complete.")
      finish_all(true)
    end)
  end)
end

---
-- 単一のモジュールのみを対象に、ファイルキャッシュを軽量に更新する
-- @param module_name string 更新したいモジュール名
-- @param on_complete function(ok) 完了時に呼ばれるコールバック
--
function M.update_file_cache_for_single_module(module_name, on_complete)
  -- 1. 必要なデータをロード
  local game_data = project_cache.load(vim.loop.cwd())
  if not game_data then
    if on_complete then on_complete(false) end
    return
  end
  local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil

  local all_modules = {}
  if game_data and game_data.modules then
    for name, meta in pairs(game_data.modules) do all_modules[name] = meta end
  end
  if engine_data and engine_data.modules then
    for name, meta in pairs(engine_data.modules) do
      if not all_modules[name] then all_modules[name] = meta end
    end
  end

  local target_module = all_modules[module_name]
  if not (target_module and target_module.module_root) then
    uep_log.get().error("Cannot update file cache: Module '%s' or its root directory not found.", module_name)
    if on_complete then on_complete(false) end
    return
  end

  -- 2. 単一モジュールのパスだけを対象にしたfdコマンドを構築
  local fd_cmd = create_fd_command({ target_module.module_root })

  local found_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(found_files, line) end
        end
      end
    end,
    -- ★★★ エラー処理を具体的に記述 ★★★
    on_stderr = function(_, data)
      if data then
        -- dataはテーブルなので、各行をループで処理する
        for _, line in ipairs(data) do
          if line and line ~= "" then
            uep_log.get().error("fd command error: %s", line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        uep_log.get().warn("fd command for single module exited with non-zero code: %d", code)
        if on_complete then on_complete(false) end
        return
      end

      -- 3. どのプロジェクト (Game/Engine) に属するモジュールか判断
      local target_project_data
      if game_data.modules and game_data.modules[module_name] then
        target_project_data = game_data
      elseif engine_data and engine_data.modules and engine_data.modules[module_name] then
        target_project_data = engine_data
      else
        uep_log.get().error("Could not determine the owner project for module '%s'.", module_name)
        if on_complete then on_complete(false) end
        return
      end

      local full_disk_cache = files_disk_cache.load(target_project_data.root)
      if not full_disk_cache then
        uep_log.get().warn("File cache for '%s' does not exist. A full ':UEP refresh' might be needed.", target_project_data.root)
        -- キャッシュがない場合は、この機会に新しいものを作成する
        full_disk_cache = {
          category = target_project_data.category,
          owner_project_root = target_project_data.root,
          files_by_module = {},
          hierarchy_nodes = {}, -- 階層情報はここでは更新できない
        }
      end

      -- 4. 対象モジュールのファイルリストを上書き
      full_disk_cache.files_by_module = full_disk_cache.files_by_module or {}
      full_disk_cache.files_by_module[module_name] = found_files

      -- 5. generationを現在のプロジェクトキャッシュと同期させる
      full_disk_cache.generation = target_project_data.generation

      -- 6. ファイルキャッシュを保存する
      files_disk_cache.save(target_project_data.root, full_disk_cache)

      uep_log.get().info("Lightweight file cache update for module '%s' complete.", module_name)
      if on_complete then on_complete(true) end
    end
  })
end

return M
