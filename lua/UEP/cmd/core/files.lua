-- lua/UEP/cmd/core/files.lua (RPC Optimized)
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")
local remote = require("UNL.db.remote")
local fs = require("vim.fs")

local M = {}

---
-- 指定されたスコープと依存関係フラグに基づいてファイルリストを取得するコア関数
function M.get_files(opts, on_complete)
  local log = uep_log.get()
  local start_time = os.clock()
  opts = opts or {}
  local requested_scope = opts.scope or "runtime"
  local requested_mode = opts.mode -- nil if not provided
  local deps_flag = opts.deps_flag or "--deep-deps"

  log.debug("core_files.get_files called with scope=%s, mode=%s, deps_flag=%s", requested_scope, tostring(requested_mode), deps_flag)

  -- STEP 1: プロジェクトの全体マップを取得 (RPC経由)
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return on_complete(false, maps)
    end

    local all_modules_map = maps.all_modules_map
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name
    local game_root = (maps.all_components_map[game_name] or {}).root_path
    local engine_root = (maps.all_components_map[engine_name] or {}).root_path
    
    log.debug("core_files: Game='%s' (root=%s), Engine='%s' (root=%s)", tostring(game_name), tostring(game_root), tostring(engine_name), tostring(engine_root))

    -- パス前方一致判定用ヘルパー
    local function path_under_root(path, root)
      if not path or not root then return false end
      local p = path:gsub("\\", "/"):lower()
      local r = root:gsub("\\", "/"):lower()
      if not r:sub(-1) == "/" then r = r .. "/" end
      local match = p:sub(1, #r) == r
      return match
    end

    -- STEP 2: 対象となるモジュールをフィルタリング
    local seed_modules = {}
    
    if requested_mode then
      log.debug("core_files: Mode filtering for '%s'...", requested_mode)
      for n, m in pairs(all_modules_map) do
        local is_owner_match = false
        if requested_scope == "game" then
          is_owner_match = (m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)
        elseif requested_scope == "engine" then
          is_owner_match = (m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)
        else
          is_owner_match = true
        end

        if is_owner_match then
          local is_type_match = false
          if requested_mode == "programs" then is_type_match = (m.type == "Program")
          elseif requested_mode == "source" then is_type_match = (m.type ~= "Program")
          else is_type_match = true end
          if is_type_match then seed_modules[n] = true end
        end
      end
    else
      log.debug("core_files: Scope filtering for '%s'...", requested_scope)
      -- Legacy Scopes
      if requested_scope == "game" then
        for n, m in pairs(all_modules_map) do 
          if m.type ~= "Program" and ((m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)) then 
            seed_modules[n] = true 
          end 
        end
      elseif requested_scope == "engine" then
        for n, m in pairs(all_modules_map) do
          if m.type ~= "Program" and ((m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)) then
            seed_modules[n] = true
          end
        end
      elseif requested_scope == "runtime" then
        for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
      elseif requested_scope == "developer" then
        for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
      elseif requested_scope == "programs" then
        for n, m in pairs(all_modules_map) do if m.type == "Program" then seed_modules[n] = true end end
      elseif requested_scope == "config" then
        for n, m in pairs(all_modules_map) do seed_modules[n] = true end
      elseif requested_scope == "editor" then
        for n, m in pairs(all_modules_map) do
          if m.type and m.type ~= "Program" then
            local ct = m.type:match("^%s*(.-)%s*$"):lower()
            if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then seed_modules[n] = true end
          end
        end
      elseif requested_scope == "full" then
        for n, m in pairs(all_modules_map) do if m.type ~= "Program" then seed_modules[n] = true end end
      else
        for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
      end
    end

    local seed_count = vim.tbl_count(seed_modules)
    log.debug("core_files: Found %d seed modules.", seed_count)

    local target_module_names = seed_modules
    if deps_flag ~= "--no-deps" then
        local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
        for mod_name, _ in pairs(seed_modules) do
            local mod_meta = all_modules_map[mod_name]
            if mod_meta and mod_meta[deps_key] then
                for _, dep_name in ipairs(mod_meta[deps_key]) do
                    local dep_meta = all_modules_map[dep_name]
                    if dep_meta then
                        local should_add = false
                        if requested_mode then
                          local is_owner_match = false
                          if requested_scope == "game" then is_owner_match = (dep_meta.owner_name == game_name or dep_meta.component_name == game_name) or path_under_root(dep_meta.module_root, game_root)
                          elseif requested_scope == "engine" then is_owner_match = (dep_meta.owner_name == engine_name or dep_meta.component_name == engine_name) or path_under_root(dep_meta.module_root, engine_root)
                          else is_owner_match = true end
                          if is_owner_match then
                             if requested_mode == "programs" then should_add = (dep_meta.type == "Program")
                             elseif requested_mode == "source" then should_add = (dep_meta.type ~= "Program")
                             else should_add = true end
                          end
                        else
                          if requested_scope == "game" or requested_scope == "engine" then
                             local root = (requested_scope == "game") and game_root or engine_root
                             local name = (requested_scope == "game") and game_name or engine_name
                             if dep_meta.type ~= "Program" and ((dep_meta.owner_name == name or dep_meta.component_name == name) or path_under_root(dep_meta.module_root, root)) then should_add = true end
                          elseif requested_scope == "editor" or requested_scope == "full" then if dep_meta.type ~= "Program" then should_add = true end
                          elseif requested_scope == "programs" then if dep_meta.type == "Program" then should_add = true end
                          elseif requested_scope == "runtime" then should_add = (dep_meta.type == "Runtime")
                          elseif requested_scope == "developer" then should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer") end
                        end
                        if should_add then target_module_names[dep_name] = true end
                    end
                end
            end
        end
    end

    -- 疑似モジュールの追加
    if deps_flag ~= "--no-deps" then
        if engine_root then
            target_module_names["_EngineConfig"] = true
            target_module_names["_EngineShaders"] = true
        end
        target_module_names["_GameConfig"] = true
        target_module_names["_GameShaders"] = true
    end

    local target_module_list = vim.tbl_keys(target_module_names)
    if #target_module_list == 0 then return on_complete(true, {}) end

    -- STEP 3: RPC経由で一括取得 (サーバー側でフィルタリング)
    log.debug("core_files.get_files: Querying RPC for files in %d modules...", #target_module_list)
    
    local extensions = nil
    local path_filter = nil
    
    if requested_mode == "config" then extensions = { "ini" }
    elseif requested_mode == "shader" then extensions = { "usf", "ush" }
    elseif requested_mode == "target_cs" then path_filter = "%.Target.cs"
    elseif requested_mode == "build_cs" then path_filter = "%.Build.cs"
    elseif requested_mode == "source" or requested_mode == "programs" then
        extensions = { "cpp", "c", "cc", "h", "hpp" }
    end
    
    remote.get_files_in_modules(target_module_list, extensions, path_filter, function(raw_files, err)
        if err then
            log.error("core_files.get_files: RPC error: %s", tostring(err))
            return on_complete(false, err)
        end

        local merged_files_with_context = {}
        for _, file in ipairs(raw_files or {}) do
            local ext = file.extension:lower()
            -- Rust側でフィルタリング済みなので、カテゴリ分けだけ行う
            local category = "other"
            if ext == "cpp" or ext == "c" or ext == "cc" or ext == "h" or ext == "hpp" then category = "source"
            elseif ext == "ini" then category = "config"
            elseif ext == "usf" or ext == "ush" then category = "shader" end

            table.insert(merged_files_with_context, {
                file_path = file.file_path,
                module_name = file.module_name,
                module_root = file.module_root,
                category = category
            })
        end

      local end_time = vim.loop.hrtime() / 1e9
      log.debug("core_files.get_files finished in %.4f seconds. Found %d files.", end_time - start_time, #merged_files_with_context)
      on_complete(true, merged_files_with_context)
    end)
  end)
end

function M.get_files_async(opts, on_partial, on_complete)
  local log = uep_log.get()
  opts = opts or {}
  local requested_scope = opts.scope or "runtime"
  local requested_mode = opts.mode
  local deps_flag = opts.deps_flag or "--deep-deps"

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then return on_complete(false, maps) end
    
    -- モジュールフィルタリング (同期版と同じロジックを期待)
    -- ここでは簡略化のため、既存のモジュールリスト作成ロジックが必要だが、
    -- 重複を避けるため後ほど整理が必要。一旦動作優先。
    -- (※本来はモジュールリスト作成だけを別関数にするのが理想)
    
    -- [中略: モジュールリスト作成ロジックが必要]
    -- 便宜上、同期版の M.get_files をラップするか、
    -- ロジックを抽出して target_module_list を得る。
    
    -- 本来あるべき姿は、モジュールリスト作成を共通化すること。
    -- 一旦 get_files の実装をコピーしてAsync呼び出しに差し替える。
    
    -- [モジュールフィルタリングロジック開始]
    local all_modules_map = maps.all_modules_map
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name
    local game_root = (maps.all_components_map[game_name] or {}).root_path
    local engine_root = (maps.all_components_map[engine_name] or {}).root_path
    local function path_under_root(path, root)
      if not path or not root then return false end
      local p = path:gsub("\\", "/"):lower(); local r = root:gsub("\\", "/"):lower()
      if not r:sub(-1) == "/" then r = r .. "/" end
      return p:sub(1, #r) == r
    end
    local seed_modules = {}
    if requested_mode then
      for n, m in pairs(all_modules_map) do
        local is_owner_match = false
        if requested_scope == "game" then is_owner_match = (m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)
        elseif requested_scope == "engine" then is_owner_match = (m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)
        else is_owner_match = true end
        if is_owner_match then
          local is_type_match = false
          if requested_mode == "programs" then is_type_match = (m.type == "Program")
          elseif requested_mode == "source" then is_type_match = (m.type ~= "Program")
          else is_type_match = true end
          if is_type_match then seed_modules[n] = true end
        end
      end
    else
      if requested_scope == "game" then for n, m in pairs(all_modules_map) do if m.type ~= "Program" and ((m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)) then seed_modules[n] = true end end
      elseif requested_scope == "engine" then for n, m in pairs(all_modules_map) do if m.type ~= "Program" and ((m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)) then seed_modules[n] = true end end
      elseif requested_scope == "runtime" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
      elseif requested_scope == "developer" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
      elseif requested_scope == "programs" then for n, m in pairs(all_modules_map) do if m.type == "Program" then seed_modules[n] = true end end
      elseif requested_scope == "config" then for n, m in pairs(all_modules_map) do seed_modules[n] = true end
      elseif requested_scope == "editor" then for n, m in pairs(all_modules_map) do if m.type and m.type ~= "Program" then local ct = m.type:match("^%s*(.-)%s*$"):lower(); if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then seed_modules[n] = true end end end
      elseif requested_scope == "full" then for n, m in pairs(all_modules_map) do if m.type ~= "Program" then seed_modules[n] = true end end
      else for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
      end
    end
    local target_module_names = seed_modules
    if deps_flag ~= "--no-deps" then
        local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
        for mod_name, _ in pairs(seed_modules) do
            local mod_meta = all_modules_map[mod_name]
            if mod_meta and mod_meta[deps_key] then
                for _, dep_name in ipairs(mod_meta[deps_key]) do
                    local dep_meta = all_modules_map[dep_name]
                    if dep_meta then
                        local should_add = false
                        if requested_mode then
                          local is_owner_match = false
                          if requested_scope == "game" then is_owner_match = (dep_meta.owner_name == game_name or dep_meta.component_name == game_name) or path_under_root(dep_meta.module_root, game_root)
                          elseif requested_scope == "engine" then is_owner_match = (dep_meta.owner_name == engine_name or dep_meta.component_name == engine_name) or path_under_root(dep_meta.module_root, engine_root)
                          else is_owner_match = true end
                          if is_owner_match then if requested_mode == "programs" then should_add = (dep_meta.type == "Program") elseif requested_mode == "source" then should_add = (dep_meta.type ~= "Program") else should_add = true end end
                        else
                          if requested_scope == "game" or requested_scope == "engine" then
                             local root = (requested_scope == "game") and game_root or engine_root; local name = (requested_scope == "game") and game_name or engine_name
                             if dep_meta.type ~= "Program" and ((dep_meta.owner_name == name or dep_meta.component_name == name) or path_under_root(dep_meta.module_root, root)) then should_add = true end
                          elseif requested_scope == "editor" or requested_scope == "full" then if dep_meta.type ~= "Program" then should_add = true end
                          elseif requested_scope == "programs" then if dep_meta.type == "Program" then should_add = true end
                          elseif requested_scope == "runtime" then should_add = (dep_meta.type == "Runtime")
                          elseif requested_scope == "developer" then should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer") end
                        end
                        if should_add then target_module_names[dep_name] = true end
                    end
                end
            end
        end
    end
    if deps_flag ~= "--no-deps" then
        if engine_root then target_module_names["_EngineConfig"] = true; target_module_names["_EngineShaders"] = true end
        target_module_names["_GameConfig"] = true; target_module_names["_GameShaders"] = true
    end
    local target_module_list = vim.tbl_keys(target_module_names)
    if #target_module_list == 0 then return on_complete(true, 0) end
    -- [モジュールフィルタリングロジック終了]

    local extensions = nil; local path_filter = nil
    if requested_mode == "config" then extensions = { "ini" }
    elseif requested_mode == "shader" then extensions = { "usf", "ush" }
    elseif requested_mode == "target_cs" then path_filter = "%.Target.cs"
    elseif requested_mode == "build_cs" then path_filter = "%.Build.cs"
    elseif requested_mode == "source" or requested_mode == "programs" then extensions = { "cpp", "c", "cc", "h", "hpp" } end
    
    local partial_handler = function(raw_files)
        local merged = {}
        for _, file in ipairs(raw_files or {}) do
            table.insert(merged, { file_path = file.file_path, module_name = file.module_name, module_root = file.module_root })
        end
        on_partial(merged)
    end

    remote.get_files_in_modules_async(target_module_list, extensions, path_filter, partial_handler, on_complete)
  end)
end

function M.search_files_async(opts, filter_text, on_partial, on_complete)
  local log = uep_log.get()
  opts = opts or {}
  local requested_scope = opts.scope or "runtime"
  local requested_mode = opts.mode
  local deps_flag = opts.deps_flag or "--deep-deps"
  local limit = opts.limit or 1000

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then return on_complete(false, maps) end
    
    -- モジュールフィルタリング (get_files_async と同様)
    -- [モジュールフィルタリングロジック開始]
    local all_modules_map = maps.all_modules_map; local game_name = maps.game_component_name; local engine_name = maps.engine_component_name
    local game_root = (maps.all_components_map[game_name] or {}).root_path; local engine_root = (maps.all_components_map[engine_name] or {}).root_path
    local function path_under_root(path, root)
      if not path or not root then return false end
      local p = path:gsub("\\", "/"):lower(); local r = root:gsub("\\", "/"):lower()
      if not r:sub(-1) == "/" then r = r .. "/" end
      return p:sub(1, #r) == r
    end
    local seed_modules = {}
    if requested_mode then
      for n, m in pairs(all_modules_map) do
        local is_owner_match = false
        if requested_scope == "game" then is_owner_match = (m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)
        elseif requested_scope == "engine" then is_owner_match = (m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)
        else is_owner_match = true end
        if is_owner_match then
          local is_type_match = false
          if requested_mode == "programs" then is_type_match = (m.type == "Program") elseif requested_mode == "source" then is_type_match = (m.type ~= "Program") else is_type_match = true end
          if is_type_match then seed_modules[n] = true end
        end
      end
    else
      if requested_scope == "game" then for n, m in pairs(all_modules_map) do if m.type ~= "Program" and ((m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)) then seed_modules[n] = true end end
      elseif requested_scope == "engine" then for n, m in pairs(all_modules_map) do if m.type ~= "Program" and ((m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)) then seed_modules[n] = true end end
      elseif requested_scope == "runtime" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
      elseif requested_scope == "developer" then for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
      elseif requested_scope == "programs" then for n, m in pairs(all_modules_map) do if m.type == "Program" then seed_modules[n] = true end end
      elseif requested_scope == "config" then for n, m in pairs(all_modules_map) do seed_modules[n] = true end
      elseif requested_scope == "editor" then for n, m in pairs(all_modules_map) do if m.type and m.type ~= "Program" then local ct = m.type:match("^%s*(.-)%s*$"):lower(); if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then seed_modules[n] = true end end end
      elseif requested_scope == "full" then for n, m in pairs(all_modules_map) do if m.type ~= "Program" then seed_modules[n] = true end end
      else for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
      end
    end
    local target_module_names = seed_modules
    if deps_flag ~= "--no-deps" then
        local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
        for mod_name, _ in pairs(seed_modules) do
            local mod_meta = all_modules_map[mod_name]
            if mod_meta and mod_meta[deps_key] then
                for _, dep_name in ipairs(mod_meta[deps_key]) do
                    local dep_meta = all_modules_map[dep_name]
                    if dep_meta then
                        local should_add = false
                        if requested_mode then
                          local is_owner_match = false
                          if requested_scope == "game" then is_owner_match = (dep_meta.owner_name == game_name or dep_meta.component_name == game_name) or path_under_root(dep_meta.module_root, game_root)
                          elseif requested_scope == "engine" then is_owner_match = (dep_meta.owner_name == engine_name or dep_meta.component_name == engine_name) or path_under_root(dep_meta.module_root, engine_root)
                          else is_owner_match = true end
                          if is_owner_match then if requested_mode == "programs" then should_add = (dep_meta.type == "Program") elseif requested_mode == "source" then should_add = (dep_meta.type ~= "Program") else should_add = true end end
                        else
                          if requested_scope == "game" or requested_scope == "engine" then
                             local root = (requested_scope == "game") and game_root or engine_root; local name = (requested_scope == "game") and game_name or engine_name
                             if dep_meta.type ~= "Program" and ((dep_meta.owner_name == name or dep_meta.component_name == name) or path_under_root(dep_meta.module_root, root)) then should_add = true end
                          elseif requested_scope == "editor" or requested_scope == "full" then if dep_meta.type ~= "Program" then should_add = true end
                          elseif requested_scope == "programs" then if dep_meta.type == "Program" then should_add = true end
                          elseif requested_scope == "runtime" then should_add = (dep_meta.type == "Runtime")
                          elseif requested_scope == "developer" then should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer") end
                        end
                        if should_add then target_module_names[dep_name] = true end
                    end
                end
            end
        end
    end
    if deps_flag ~= "--no-deps" then
        if engine_root then target_module_names["_EngineConfig"] = true; target_module_names["_EngineShaders"] = true end
        target_module_names["_GameConfig"] = true; target_module_names["_GameShaders"] = true
    end
    local target_module_list = vim.tbl_keys(target_module_names)
    if #target_module_list == 0 then return on_complete(true, 0) end
    -- [モジュールフィルタリングロジック終了]

    local partial_handler = function(raw_files)
        local merged = {}
        for _, file in ipairs(raw_files or {}) do
            table.insert(merged, { file_path = file.file_path, module_name = file.module_name, module_root = file.module_root })
        end
        on_partial(merged)
    end

    remote.search_files_in_modules_async(target_module_list, filter_text, limit, partial_handler, on_complete)
  end)
end

---
-- 指定されたスコープ、依存関係フラグ、フィルタ文字列に基づいてファイルリストを取得するコア関数
function M.search_files(opts, filter_text, on_complete)
  local log = uep_log.get()
  local start_time = os.clock()
  opts = opts or {}
  local requested_scope = opts.scope or "runtime"
  local requested_mode = opts.mode -- nil if not provided
  local deps_flag = opts.deps_flag or "--deep-deps"
  local limit = opts.limit or 200

  log.debug("core_files.search_files called with scope=%s, mode=%s, deps_flag=%s, filter='%s'", requested_scope, tostring(requested_mode), deps_flag, filter_text)

  -- STEP 1: プロジェクトの全体マップを取得 (RPC経由)
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return on_complete(false, maps)
    end

    local all_modules_map = maps.all_modules_map
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name
    local game_root = (maps.all_components_map[game_name] or {}).root_path
    local engine_root = (maps.all_components_map[engine_name] or {}).root_path
    
    -- パス前方一致判定用ヘルパー
    local function path_under_root(path, root)
      if not path or not root then return false end
      local p = path:gsub("\\", "/"):lower()
      local r = root:gsub("\\", "/"):lower()
      if not r:sub(-1) == "/" then r = r .. "/" end
      local match = p:sub(1, #r) == r
      return match
    end

    -- STEP 2: 対象となるモジュールをフィルタリング (get_filesと同じロジック)
    local seed_modules = {}
    
    if requested_mode then
      for n, m in pairs(all_modules_map) do
        local is_owner_match = false
        if requested_scope == "game" then
          is_owner_match = (m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)
        elseif requested_scope == "engine" then
          is_owner_match = (m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)
        else
          is_owner_match = true
        end

        if is_owner_match then
          local is_type_match = false
          if requested_mode == "programs" then is_type_match = (m.type == "Program")
          elseif requested_mode == "source" then is_type_match = (m.type ~= "Program")
          else is_type_match = true end
          if is_type_match then seed_modules[n] = true end
        end
      end
    else
      -- Legacy Scopes
      if requested_scope == "game" then
        for n, m in pairs(all_modules_map) do 
          if m.type ~= "Program" and ((m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)) then 
            seed_modules[n] = true 
          end 
        end
      elseif requested_scope == "engine" then
        for n, m in pairs(all_modules_map) do
          if m.type ~= "Program" and ((m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)) then
            seed_modules[n] = true
          end
        end
      elseif requested_scope == "runtime" then
        for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
      elseif requested_scope == "developer" then
        for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
      elseif requested_scope == "programs" then
        for n, m in pairs(all_modules_map) do if m.type == "Program" then seed_modules[n] = true end end
      elseif requested_scope == "config" then
        for n, m in pairs(all_modules_map) do seed_modules[n] = true end
      elseif requested_scope == "editor" then
        for n, m in pairs(all_modules_map) do
          if m.type and m.type ~= "Program" then
            local ct = m.type:match("^%s*(.-)%s*$"):lower()
            if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then seed_modules[n] = true end
          end
        end
      elseif requested_scope == "full" then
        for n, m in pairs(all_modules_map) do if m.type ~= "Program" then seed_modules[n] = true end end
      else
        for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
      end
    end

    local target_module_names = seed_modules
    if deps_flag ~= "--no-deps" then
        local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
        for mod_name, _ in pairs(seed_modules) do
            local mod_meta = all_modules_map[mod_name]
            if mod_meta and mod_meta[deps_key] then
                for _, dep_name in ipairs(mod_meta[deps_key]) do
                    local dep_meta = all_modules_map[dep_name]
                    if dep_meta then
                        local should_add = false
                        if requested_mode then
                          local is_owner_match = false
                          if requested_scope == "game" then is_owner_match = (dep_meta.owner_name == game_name or dep_meta.component_name == game_name) or path_under_root(dep_meta.module_root, game_root)
                          elseif requested_scope == "engine" then is_owner_match = (dep_meta.owner_name == engine_name or dep_meta.component_name == engine_name) or path_under_root(dep_meta.module_root, engine_root)
                          else is_owner_match = true end
                          if is_owner_match then
                             if requested_mode == "programs" then should_add = (dep_meta.type == "Program")
                             elseif requested_mode == "source" then should_add = (dep_meta.type ~= "Program")
                             else should_add = true end
                          end
                        else
                          if requested_scope == "game" or requested_scope == "engine" then
                             local root = (requested_scope == "game") and game_root or engine_root
                             local name = (requested_scope == "game") and game_name or engine_name
                             if dep_meta.type ~= "Program" and ((dep_meta.owner_name == name or dep_meta.component_name == name) or path_under_root(dep_meta.module_root, root)) then should_add = true end
                          elseif requested_scope == "editor" or requested_scope == "full" then if dep_meta.type ~= "Program" then should_add = true end
                          elseif requested_scope == "programs" then if dep_meta.type == "Program" then should_add = true end
                          elseif requested_scope == "runtime" then should_add = (dep_meta.type == "Runtime")
                          elseif requested_scope == "developer" then should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer") end
                        end
                        if should_add then target_module_names[dep_name] = true end
                    end
                end
            end
        end
    end

    -- 疑似モジュールの追加
    if deps_flag ~= "--no-deps" then
        if engine_root then
            target_module_names["_EngineConfig"] = true
            target_module_names["_EngineShaders"] = true
        end
        target_module_names["_GameConfig"] = true
        target_module_names["_GameShaders"] = true
    end

    local target_module_list = vim.tbl_keys(target_module_names)
    if #target_module_list == 0 then return on_complete(true, {}) end

    -- STEP 3: RPC経由で検索 (SearchFilesInModules)
    log.debug("core_files.search_files: Searching RPC for '%s' in %d modules...", filter_text, #target_module_list)
    
    remote.search_files_in_modules(target_module_list, filter_text, limit, function(raw_files, err)
        if err then
            log.error("core_files.search_files: RPC error: %s", tostring(err))
            return on_complete(false, err)
        end

        local merged_files_with_context = {}
        for _, file in ipairs(raw_files or {}) do
            local ext = file.extension:lower()
            local path = file.file_path
            
            -- カテゴリ判定
            local category = "other"
            if ext == "cpp" or ext == "c" or ext == "cc" or ext == "h" or ext == "hpp" then category = "source"
            elseif ext == "ini" then category = "config"
            elseif ext == "usf" or ext == "ush" then category = "shader" end

            local should_include = true
            if requested_mode then
                if requested_mode == "config" then should_include = (category == "config")
                elseif requested_mode == "shader" then should_include = (category == "shader")
                elseif requested_mode == "programs" then should_include = (category == "source")
                elseif requested_mode == "source" then should_include = (category == "source")
                elseif requested_mode == "target_cs" then should_include = path:match("%.Target%.cs$")
                elseif requested_mode == "build_cs" then should_include = path:match("%.Build%.cs$") end
                
                -- Shaders filtering for source/programs
                if (requested_mode == "source" or requested_mode == "programs") and category == "shader" then
                    should_include = false
                end
            else
                if requested_scope == "config" and category ~= "config" then should_include = false end
            end

            if should_include then
                table.insert(merged_files_with_context, {
                    file_path = path,
                    module_name = file.module_name,
                    module_root = file.module_root,
                    category = category
                })
            end
        end

      local end_time = vim.loop.hrtime() / 1e9
      log.debug("core_files.search_files finished in %.4f seconds. Found %d files.", end_time - start_time, #merged_files_with_context)
      on_complete(true, merged_files_with_context)
    end)
  end)
end

-- モジュール単体のファイル取得
function M.get_files_for_module(module_name, on_complete)
  local log = uep_log.get()
  remote.get_module_by_name(module_name, function(mod_data, err) 
    if err or not mod_data then
        if on_complete then on_complete(false, err or "Module not found") end
        return
    end
    -- mod_data is { name, module_root, path, files={source, config, shader, other} }
    local files = {}
    for _, list in pairs(mod_data.files) do
        vim.list_extend(files, list)
    end
    on_complete(true, { files = files, module_meta = mod_data })
  end)
end

function M.get_all_cached_items(opts, on_complete)
  -- This is used by neo-tree or fuzzy finders for broad search.
  -- Simplified version: just get all files from DB.
  remote.get_all_file_paths(function(paths, err) 
    if err then return on_complete(false, err) end
    local items = {}
    for _, p in ipairs(paths or {}) do
        table.insert(items, { path = p, type = "file" })
    end
    on_complete(true, items)
  end)
end

return M