-- lua/UEP/cmd/refresh.lua

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
-- local event_types = require("UEP.event.types")
local unl_events = require("UNL.event.events")
local unl_events = require("UNL.event.types")

local M = {}

-------------------------------------------------
-- Helper Functions
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
  local full_path_regex = ".*[\\\\/](Source|Config|Plugins)[\\\\/].*\\.(" .. table.concat(extensions, "|") .. ")$"
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

---
-- フラットなファイルパスのリストから、ネストした階層構造を構築する
-- @param file_list table ファイルパスの文字列のリスト
-- @param root_path string 階層の基点となるパス
-- @return table neo-tree 形式のノードのリスト
--
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
---
-- 解析済みのモジュールリストから、neo-treeで表示するための階層ノードを構築する
-- @param modules_meta table<string, ModuleInfo> 解析済みのモジュール情報
-- @param project_type string "Game" または "Engine"
-- @param files_by_module table<string, table<string>> モジュール名とそのファイルリストのマップ
-- @return table UI非依存の階層データ
--
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

local function create_file_cache(scope, project_data, engine_data, progress, on_complete)
  local search_path = (scope == "Game" or scope == "Engine") and project_data.root or nil
  if not search_path then
    if on_complete then on_complete(false) end; return
  end
  local fd_cmd = create_fd_command({ search_path })
  local found_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(found_files, line) end end end end,
    on_exit = function(_, code)
      if code ~= 0 then if on_complete then on_complete(false) end; return end
      local all_files_by_module = {}
      local all_modules_meta = vim.tbl_extend("force", {}, engine_data and engine_data.modules or {}, project_data and project_data.modules or {})
      local sorted_modules = {}
      for name, meta in pairs(all_modules_meta) do if meta.module_root then table.insert(sorted_modules, { name = name, root = meta.module_root .. "/" }) end end
      table.sort(sorted_modules, function(a, b) return #a.root > #b.root end)
      for _, file_path in ipairs(found_files) do
        local owner = find_owner_module(file_path, sorted_modules)
        if owner then
          if not all_files_by_module[owner] then all_files_by_module[owner] = {} end
          table.insert(all_files_by_module[owner], file_path)
        end
      end
      local hierarchy_data = build_hierarchy_nodes(project_data.modules, scope, all_files_by_module)
      local cache_to_save = { category = scope, generation = project_data.generation, owner_project_root = project_data.root, files_by_module = all_files_by_module, hierarchy_nodes = hierarchy_data }
      files_disk_cache.save(project_data.root, cache_to_save)
      -- ★★★ ファイルキャッシュ保存後にイベント発行 ★★★
      unl_events.publish(unl_events.ON_AFTER_FILE_CACHE_SAVE)
      if on_complete then on_complete(true) end
    end,
  })
end

-------------------------------------------------
-- Coroutine and Job Management
-------------------------------------------------

-- cmd/refresh.lua



-- Coroutine and Job Management
local function processor_coroutine(params)
  local progress = params.progress
  progress:stage_define("parse_modules", #params.build_cs_files)

  local modules_meta = {}
  for i, raw_path in ipairs(params.build_cs_files) do
    local build_cs_path = unl_path.normalize(raw_path)
    local module_name = vim.fn.fnamemodify(build_cs_path, ":h:t")
    progress:stage_update("parse_modules", i, "Parsing: " .. module_name)
    local module_root = vim.fn.fnamemodify(build_cs_path, ":h")
    local location = "unknown"
    if build_cs_path:find("/Plugins/", 1, true) then location = "in_plugins" elseif build_cs_path:find("/Source/", 1, true) then location = "in_source" end
    local dependencies = unl_analyzer.parse(build_cs_path)
    modules_meta[module_name] = { name = module_name, path = build_cs_path, module_root = module_root, category = params.type, location = location, dependencies = dependencies }
    if i % 20 == 0 then coroutine.yield() end
  end
  progress:stage_update("parse_modules", #params.build_cs_files, "All modules parsed")
  coroutine.yield()

  progress:stage_define("resolve_deps", 1)
  progress:stage_update("resolve_deps", 0, "Building dependency graph...")

  local modules_with_resolved_deps, err = uep_graph.resolve_all_dependencies(modules_meta, params.engine_cache and params.engine_cache.modules or nil, progress)
  if not modules_with_resolved_deps or type(modules_with_resolved_deps) ~= "table" then
    progress:finish(false); return false
  end
  progress:stage_define("save_cache", 1)
  progress:stage_update("save_cache", 0, "Saving project cache...")

  local content_to_hash = vim.json.encode(modules_with_resolved_deps)
  local data_hash = vim.fn.sha256(content_to_hash)
  local project_data_to_save = { generation = data_hash, modules = modules_with_resolved_deps, root = params.root_path }

  if params.type == "Game" then
    project_data_to_save.uproject_path = unl_finder.project.find_project_file(params.root_path)
    project_data_to_save.link_engine_cache_root = params.engine_root
  end

  local ok, save_err = project_cache.save(params.root_path, params.type, project_data_to_save)
  if not ok then
    progress:finish(false); return false
  end
  -- ★★★ プロジェクトキャッシュ保存後にイベント発行 ★★★
  unl_events.publish(unl_events.ON_AFTER_PROJECT_CACHE_SAVE)
  progress:stage_update("save_cache", 1, "Project cache saved.")
  if params.type == "Game" and project_data_to_save.uproject_path then
    projects_cache.add_or_update({ root = params.root_path, uproject_path = project_data_to_save.uproject_path, engine_root_path = params.engine_root })
  end

  progress:stage_define("create_file_cache", 1)
  progress:stage_update("create_file_cache", 0, "Creating file cache...")
  coroutine.yield()

  create_file_cache(params.type, project_data_to_save, params.engine_cache, progress, function(ok)
    if ok then
      progress:stage_update("create_file_cache", 1, "File cache created.")
      -- ★★★ リフレッシュ全体の完了イベントを発行 ★★★
      unl_events.publish(unl_events.ON_AFTER_REFRESH_COMPLETED, { status = "success" })
    else
      progress:stage_update("create_file_cache", 1, "Failed to create file cache.", { error = true })
      unl_events.publish(unl_events.ON_AFTER_REFRESH_COMPLETED, { status = "failed" })
    end
    progress:finish(true)
    if params.on_complete then params.on_complete(ok) end
  end)
end

local function start_refresh_job(root_path, type, on_complete)
  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, { title = ("UEP: Refreshing %s..."):format(type), client_name = "UEP" })
  if not progress then if on_complete then on_complete(false) end; return end

  local search_paths, engine_root_for_job
  if type == "Game" then
    local proj_info = unl_finder.project.find_project(root_path)
    engine_root_for_job = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject, {}) or nil
    search_paths = { fs.joinpath(root_path, "Source"), fs.joinpath(root_path, "Plugins") }
  else
    engine_root_for_job = root_path
    search_paths = { fs.joinpath(root_path, "Engine", "Source"), fs.joinpath(root_path, "Engine", "Plugins") }
  end

  progress:open()

  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "Build.cs", unpack(tbl_unique(search_paths)) }
  local build_cs_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(build_cs_files, line) end end end end,
    on_exit = function(_, code)
      if code ~= 0 then progress:finish(false); if on_complete then on_complete(false) end; return end
      if #build_cs_files == 0 then progress:finish(true); if on_complete then on_complete(true) end; return end
      local engine_cache_for_job = (type == "Game" and engine_root_for_job) and project_cache.load(engine_root_for_job) or nil
      local co = coroutine.create(processor_coroutine)
      local function resume_handler()
        local params = { root_path = root_path, type = type, engine_root = engine_root_for_job, build_cs_files = build_cs_files, progress = progress, engine_cache = engine_cache_for_job, on_complete = on_complete }
        local status, result_or_err = coroutine.resume(co, params)
        if not status then progress:finish(false); if on_complete then on_complete(false) end; return end
        if coroutine.status(co) ~= "dead" then vim.defer_fn(resume_handler, 1) end
      end
      resume_handler()
    end,
  })
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function M.execute(opts, on_complete)
  local type_arg = opts.type or "Game"
  local type = (type_arg:lower() == "engine") and "Engine" or "Game"
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    uep_log.get().error("Not in an Unreal Engine project directory.")
    if on_complete then on_complete(false) end
    return
  end
  
  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject, {}) or nil

  if type == "Game" then
    if engine_root and not project_cache.exists(engine_root) then
      uep_log.get().info("Engine cache not found. Creating it first...")
      start_refresh_job(engine_root, "Engine", function(ok)
        if ok then
          uep_log.get().info("Engine cache created. Now refreshing game...")
          start_refresh_job(project_root, "Game", on_complete)
        else
          uep_log.get().error("Failed to create Engine cache. Aborting game refresh.")
          if on_complete then on_complete(false) end
        end
      end)
    else
      start_refresh_job(project_root, "Game", on_complete)
    end
  else
    if not engine_root then 
      uep_log.get().error("Could not find engine root for refresh.")
      if on_complete then on_complete(false) end
      return 
    end
    start_refresh_job(engine_root, "Engine", on_complete)
  end
end

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
    on_stderr = function(...) end, -- エラー処理は省略
    on_exit = function(_, code)
      if code ~= 0 then
        if on_complete then on_complete(false) end
        return
      end


     
      local target_data = {}
      if game_data.modules[module_name] then
        target_data  = game_data
      elseif engine_data.modules[module_name] then
        target_data  = engine_data
      end
      
      local full_disk_cache = files_disk_cache.load( target_data.root)

      -- 4. 対象モジュールのファイルリストを上書き
      full_disk_cache.files_by_module[module_name] = found_files
      
      -- 5. generationを現在のプロジェクトキャッシュと同期させる
      full_disk_cache.generation = target_data.generation

      -- 6. セーブ＆内部でキャッシュにもせーぶさせる
      files_disk_cache.save(target_data.root, full_disk_cache)
      -- require("UNL.context").use("UEP"):key(target_data.root):set("file_cache", target_data)
      
      uep_log.get().info("Lightweight file cache update for module '%s' complete.", module_name)
      if on_complete then on_complete(true) end
    end,
  })
end


return M
