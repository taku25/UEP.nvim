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

local function build_hierarchy_nodes(modules_meta, project_type, files_by_module)
  local root_nodes = {
    Game = { id = project_type .. "_Game", name = "Game", type = "directory", extra = { uep_type = "category" }, children = {} },
    Plugins = { id = project_type .. "_Plugins", name = "Plugins", type = "directory", extra = { uep_type = "category" }, children = {} },
  }
  if project_type == "Engine" then
    root_nodes["Engine"] = { id = project_type .. "_Engine", name = "Engine", type = "directory", extra = { uep_type = "category" }, children = {} }
  end
  local plugin_nodes = {}
  for name, meta in pairs(modules_meta) do
    if meta.module_root then
      local module_files = files_by_module[name] or {}
      local file_tree = build_fs_tree_from_flat_list(module_files, meta.module_root)
      local node = { id = meta.module_root, name = name, path = meta.module_root, type = "directory", extra = { uep_type = "module" }, children = file_tree }
      if meta.location == "in_plugins" then
        local plugin_name = meta.module_root:match("[/\\]Plugins[/\\]([^/\\]+)")
        if plugin_name then
          if not plugin_nodes[plugin_name] then
            local plugin_path = meta.module_root:match("(.+[/\\]Plugins[/\\][^/\\]+)")
            plugin_nodes[plugin_name] = { id = plugin_path, name = plugin_name, path = plugin_path, type = "directory", extra = { uep_type = "plugin" }, children = {} }
          end
          table.insert(plugin_nodes[plugin_name].children, node)
        else
          table.insert(root_nodes.Plugins.children, node)
        end
      elseif meta.location == "in_source" then
        local category_key = (project_type == "Engine") and "Engine" or "Game"
        if root_nodes[category_key] then table.insert(root_nodes[category_key].children, node) end
      end
    end
  end
  for _, plugin_node in pairs(plugin_nodes) do table.insert(root_nodes.Plugins.children, plugin_node) end
  local final_nodes = {}
  local categories_order = { "Game", "Engine", "Plugins" }
  for _, category_name in ipairs(categories_order) do
    local category_node = root_nodes[category_name]
    if category_node and #category_node.children > 0 then
      category_node.path = category_node.id
      table.insert(final_nodes, category_node)
    end
  end
  return final_nodes
end

-------------------------------------------------
-- New & Refactored Core Functions
-------------------------------------------------

--- ファイルキャッシュ作成処理 (UI応答性改善版)
local function create_file_cache(scope, project_data, engine_data, progress, on_complete)
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
          if line ~= "" then table.insert(found_files, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        progress:stage_update("create_file_cache", 1, "Failed to list files.", { error = true })
        if on_complete then on_complete(false) end
        return
      end

      -- ★★★ ここからが大きな変更点 ★★★
      -- UIをブロックしないように、ループ処理をチャンクに分割して遅延実行する
      local all_files_by_module = {}
      local all_modules_meta = vim.tbl_extend("force", {}, engine_data and engine_data.modules or {}, project_data.modules)
      local sorted_modules = {}
      for name, meta in pairs(all_modules_meta) do if meta.module_root then table.insert(sorted_modules, { name = name, root = meta.module_root .. "/" }) end end
      table.sort(sorted_modules, function(a, b) return #a.root > #b.root end)

      local i = 1
      local total_files = #found_files
      local chunk_size = 500 -- 一度に処理するファイル数 (この値で応答性を調整可能)

      local function process_chunk()
        progress:stage_update("create_file_cache", (i / total_files), ("Processing files (%d/%d)..."):format(i, total_files))

        local chunk_limit = math.min(i + chunk_size - 1, total_files)
        for j = i, chunk_limit do
          local file_path = found_files[j]
          local owner = find_owner_module(file_path, sorted_modules)
          if owner then
            if not all_files_by_module[owner] then all_files_by_module[owner] = {} end
            table.insert(all_files_by_module[owner], file_path)
          end
        end

        i = i + chunk_size

        if i <= total_files then
          -- まだ処理するファイルが残っていれば、次のチャンクを遅延実行
          vim.defer_fn(process_chunk, 1) -- 1ms後に次のチャンクへ
        else
          -- 全てのファイルの処理が完了した
          progress:stage_update("create_file_cache", 1, "Building file hierarchy...")
          -- 階層データの構築は比較的速いので、ここはyieldなしで実行
          local hierarchy_data = build_hierarchy_nodes(project_data.modules, scope, all_files_by_module)
          local cache_to_save = { category = scope, generation = project_data.generation, owner_project_root = project_data.root, files_by_module = all_files_by_module, hierarchy_nodes = hierarchy_data }

          files_disk_cache.save(project_data.root, cache_to_save)
          progress:stage_update("create_file_cache", 1, "File cache for " .. scope .. " created.")
          if on_complete then on_complete(true) end
        end
      end

      -- 最初のチャンク処理を開始
      if total_files > 0 then
        process_chunk()
      else
        -- ファイルが一つもなくてもキャッシュファイルは作成する
        local cache_to_save = { category = scope, generation = project_data.generation, owner_project_root = project_data.root, files_by_module = {}, hierarchy_nodes = {} }
        files_disk_cache.save(project_data.root, cache_to_save)
        progress:stage_update("create_file_cache", 1, "File cache for " .. scope .. " created (no files).")
        if on_complete then on_complete(true) end
      end
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
      -- 完了コールバックには、最終的に使われたデータを渡す
      on_complete(file_cache_ok, data_for_files_cache)
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
    uep_log.get():error("Cannot update file cache: Module '%s' or its root directory not found.", module_name)
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
        for _, line in ipairs(data) do
          if line ~= "" then
            uep_log.get().error("Error during single module file search (fd): %s", line)
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
