-- lua/UEP/cmd/core/files.lua
local uep_db = require("UEP.db.init")
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")
local fs = require("vim.fs")

local M = {}

-- DB からモジュールのファイルを引き出すヘルパー（SQLite移行用）。
local function get_module_files_from_db(module_name, module_root)
  local db = uep_db.get()
  if not db then return nil end

  local db_query = require("UEP.db.query")
  local rows = db_query.get_module_files_by_name_and_root(db, module_name, module_root)

  if type(rows) ~= "table" or #rows == 0 then
    return nil
  end

  local files = { source = {}, config = {}, shader = {}, other = {} }
  for _, row in ipairs(rows) do
    local ext = row.extension
    local path = row.path

    if ext == "cpp" or ext == "c" or ext == "cc" or ext == "h" or ext == "hpp" then
      table.insert(files.source, path)
    elseif ext == "ini" then
      table.insert(files.config, path)
    elseif ext == "usf" or ext == "ush" then
      table.insert(files.shader, path)
      -- Shader files are also source files in a broad sense, but we keep them separate in 'shader' category.
      -- However, if 'source' mode is requested, we might want to exclude them or include them depending on policy.
      -- Current policy: 'source' mode excludes shaders. 'shader' mode includes ONLY shaders.
    else
      table.insert(files.other, path)
    end
  end

  return files
end

-- DB からモジュールのディレクトリを引き出すヘルパー（カテゴリ付き）。
local function get_module_dirs_from_db(module_name, module_root)
  local db = uep_db.get()
  if not db then return nil end

  local db_query = require("UEP.db.query")
  local rows = db_query.get_module_dirs_by_name_and_root(db, module_name, module_root)

  if type(rows) ~= "table" or #rows == 0 then
    return nil
  end

  local dirs = { source = {}, config = {}, shader = {}, other = {}, programs = {}, content = {} }
  for _, row in ipairs(rows) do
    local cat = row.category or "other"
    if not dirs[cat] then dirs[cat] = {} end
    table.insert(dirs[cat], row.path)
  end

  return dirs
end

---
-- 指定されたスコープと依存関係フラグに基づいてファイルリストを取得する新しいコア関数
function M.get_files(opts, on_complete)
  local log = uep_log.get()
  local start_time = os.clock()
  opts = opts or {}
  local requested_scope = opts.scope or "runtime"
  local requested_mode = opts.mode -- nil if not provided
  local deps_flag = opts.deps_flag or "--deep-deps"

  log.debug("core_files.get_files called with scope=%s, mode=%s, deps_flag=%s", requested_scope, tostring(requested_mode), deps_flag)

  -- STEP 1: プロジェクトの全体マップを取得
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      -- エラーメッセージが "No components in DB" の場合はログを出さない (utils側で出ているため)
      if not (type(maps) == "string" and maps:find("No components in DB")) then
        log.error("core_files.get_files: Failed to get project maps: %s", tostring(maps))
      end
      return on_complete(false, maps)
    end

    local all_modules_map = maps.all_modules_map
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name

    -- パス前方一致を使ったフォールバック判定（owner/component が欠落している古いDBでも拾う）
    local function path_under_root(path, root)
      if not path or not root then return false end
      local p = path:gsub("\\", "/")
      local r = root:gsub("\\", "/")
      if not r:match("/$") then r = r .. "/" end
      return p:sub(1, #r):lower() == r:lower()
    end

    local game_root = (maps.all_components_map[game_name] or {}).root_path
    local engine_root = (maps.all_components_map[engine_name] or {}).root_path

    -- STEP 2: 対象となるモジュールをフィルタリング
    local target_module_names = {}
    local seed_modules = {}
    
    -- 2a: スコープに基づいて起点モジュールを決定
    if requested_mode then
      -- ★★★ 新モードロジック ★★★
      for n, m in pairs(all_modules_map) do
        local is_owner_match = false
        if requested_scope == "game" then
          is_owner_match = (m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)
        elseif requested_scope == "engine" then
          is_owner_match = (m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root)
        else -- full, all, etc.
          is_owner_match = true
        end

        if is_owner_match then
          local is_type_match = false
          if requested_mode == "programs" then
            is_type_match = (m.type == "Program")
          elseif requested_mode == "source" then
            is_type_match = (m.type ~= "Program") -- Source usually means non-program source
          else -- config, shader
            is_type_match = true -- Config/Shader can be anywhere
          end

          if is_type_match then
            seed_modules[n] = true
          end
        end
      end
    else
      -- ★★★ 既存ロジック (Legacy) ★★★
      if requested_scope == "game" then
        for n, m in pairs(all_modules_map) do 
          -- owner/component が一致、もしくはモジュールルートがゲームルート配下
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
        for n, m in pairs(all_modules_map) do
          if m.type == "Runtime" then
            seed_modules[n] = true
          end
        end
      elseif requested_scope == "developer" then
        for n, m in pairs(all_modules_map) do
          if m.type == "Runtime" or m.type == "Developer" then
            seed_modules[n] = true
          end
        end
      elseif requested_scope == "programs" then
        for n, m in pairs(all_modules_map) do
          if m.type == "Program" then
            seed_modules[n] = true
          end
        end
      elseif requested_scope == "config" then
        -- Config scope: Include ALL modules to scan for .ini files later
        for n, m in pairs(all_modules_map) do
            seed_modules[n] = true
        end
      elseif requested_scope == "editor" then
        for n, m in pairs(all_modules_map) do
          if m.type and m.type ~= "Program" then
            local ct = m.type:match("^%s*(.-)%s*$"):lower()
            if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then
              seed_modules[n] = true
            end
          end
        end
      
      elseif requested_scope == "full" then
        for n, m in pairs(all_modules_map) do
          if m.type ~= "Program" then 
            seed_modules[n] = true
          end
        end

      else -- Unknown scope defaults to runtime
        requested_scope = "runtime"
        for n, m in pairs(all_modules_map) do
          if m.type == "Runtime" then
            seed_modules[n] = true
          end
        end
      end
    end

    -- 2b: 依存関係フラグに基づきモジュールを追加
    target_module_names = seed_modules
    
    if deps_flag ~= "--no-deps" then
        local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
        log.debug("Deps: %s. Using key: %s", deps_flag, deps_key)
        
        for mod_name, _ in pairs(seed_modules) do
            local mod_meta = all_modules_map[mod_name]
            if mod_meta and mod_meta[deps_key] then
                for _, dep_name in ipairs(mod_meta[deps_key]) do
                    local dep_meta = all_modules_map[dep_name]
                    if dep_meta then
                        local should_add = false
                        
                        if requested_mode then
                          -- ★★★ 新モードロジック (依存関係も厳密にフィルタ) ★★★
                          local is_owner_match = false
                          if requested_scope == "game" then
                            is_owner_match = (dep_meta.owner_name == game_name or dep_meta.component_name == game_name) or path_under_root(dep_meta.module_root, game_root)
                          elseif requested_scope == "engine" then
                            is_owner_match = (dep_meta.owner_name == engine_name or dep_meta.component_name == engine_name) or path_under_root(dep_meta.module_root, engine_root)
                          else
                            is_owner_match = true
                          end
                          
                          if is_owner_match then
                             if requested_mode == "programs" then should_add = (dep_meta.type == "Program")
                             elseif requested_mode == "source" then should_add = (dep_meta.type ~= "Program")
                             else should_add = true end
                          end
                        else
                          -- ★★★ 既存ロジック (Legacy) ★★★
                          if requested_scope == "game" then
                            if dep_meta.type and dep_meta.type ~= "Program" and ((dep_meta.owner_name == game_name or dep_meta.component_name == game_name) or path_under_root(dep_meta.module_root, game_root)) then
                              should_add = true
                            end
                          elseif requested_scope == "engine" then
                            if dep_meta.type and dep_meta.type ~= "Program" and ((dep_meta.owner_name == engine_name or dep_meta.component_name == engine_name) or path_under_root(dep_meta.module_root, engine_root)) then
                              should_add = true
                            end
                          elseif requested_scope == "editor" or requested_scope == "full" then
                            if dep_meta.type and dep_meta.type ~= "Program" then
                              should_add = true
                            end
                          elseif requested_scope == "programs" then
                            if dep_meta.type == "Program" then
                              should_add = true
                            end
                          elseif requested_scope == "runtime" then 
                              should_add = (dep_meta.type == "Runtime")
                          elseif requested_scope == "developer" then 
                              should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer")
                          end
                        end
                        
                        if should_add then
                            target_module_names[dep_name] = true
                        end
                    end
                end
            end
        end
    end

    local filtered_module_count = vim.tbl_count(target_module_names)
    log.debug("core_files.get_files: Filtered down to %d modules for scope=%s, deps=%s", filtered_module_count, requested_scope, deps_flag)
    if filtered_module_count == 0 then
      log.warn("core_files.get_files: No modules matched the filter.")
      return on_complete(true, {})
    end

    -- STEP 3: 対象モジュールのキャッシュをロードしてファイルを集約（SQLiteのみ）
    local merged_files_with_context = {}
    local modules_processed = 0
    
    local allow_programs_category = (requested_scope == "programs")
    for mod_name, _ in pairs(target_module_names) do
      local mod_meta = all_modules_map[mod_name]
      if mod_meta then
        local files_from_db = get_module_files_from_db(mod_name, mod_meta.module_root)

        if files_from_db then
          for category, files in pairs(files_from_db) do
            local should_include = false

            if requested_mode then
                -- ★★★ 新モードロジック ★★★
                if requested_mode == "config" then
                    should_include = (category == "config")
                elseif requested_mode == "shader" then
                    should_include = (category == "shader")
                elseif requested_mode == "programs" then
                    should_include = (category == "source" or category == "programs")
                elseif requested_mode == "source" then
                    should_include = (category == "source")
                end
            else
                -- ★★★ 既存ロジック (Legacy) ★★★
                should_include = true
                if requested_scope == "config" and category ~= "config" then should_include = false end
                if not allow_programs_category and category == "programs" then should_include = false end
            end

            if should_include then
              for _, file_path in ipairs(files) do
                local add_file = true
                
                if requested_mode == "shader" then
                    add_file = (file_path:match("%.usf$") or file_path:match("%.ush$"))
                elseif requested_mode == "source" or requested_mode == "programs" then
                    if file_path:match("%.usf$") or file_path:match("%.ush$") then
                        add_file = false
                    end
                end

                if add_file then
                    table.insert(merged_files_with_context, {
                      file_path = file_path, module_name = mod_name, module_root = mod_meta.module_root, category = category
                    })
                end
              end
            end
          end
        end
        modules_processed = modules_processed + 1
      end
    end

    -- STEP 4: スコープとDepsフラグに応じて、疑似モジュール(Plugin/Game/Engine)を追加
    local pseudo_module_files = {}

    -- 1. Engine の疑似モジュール (_EngineShaders 等)
    local add_engine_pseudos = false
    if deps_flag ~= "--no-deps" then
        if requested_scope == "engine" or requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" or requested_scope == "programs" then
            add_engine_pseudos = true
        end
    end

    if add_engine_pseudos and maps.engine_root then
        if requested_mode then
            if requested_mode == "shader" then
                pseudo_module_files._EngineShaders = { root=fs.joinpath(maps.engine_root, "Engine", "Shaders") }
            elseif requested_mode == "config" then
                pseudo_module_files._EngineConfig  = { root=fs.joinpath(maps.engine_root, "Engine", "Config") }
            elseif requested_mode == "programs" then
                pseudo_module_files._EnginePrograms = { root=fs.joinpath(maps.engine_root, "Engine", "Source", "Programs") }
            end
        else
            if requested_scope ~= "programs" then
                pseudo_module_files._EngineShaders = { root=fs.joinpath(maps.engine_root, "Engine", "Shaders") }
                pseudo_module_files._EngineConfig  = { root=fs.joinpath(maps.engine_root, "Engine", "Config") }
            end
            if requested_scope == "programs" or requested_scope == "full" then
                pseudo_module_files._EnginePrograms = { root=fs.joinpath(maps.engine_root, "Engine", "Source", "Programs") }
            end
        end
    end

    -- 2. Game / Plugin の疑似モジュール (Game_MyProj, Plugin_MyPlugin 等)
    local add_project_pseudos = false
    if requested_scope == "game" or requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" then
        add_project_pseudos = true
    end

    if add_project_pseudos then
        for comp_name_hash, comp_meta in pairs(maps.all_components_map) do
            local should_add = false
            if comp_meta.type == "Game" then
                should_add = true
            elseif comp_meta.type == "Plugin" then
                -- Plugin内のShader/Config等はランタイムスコープでも必要になることが多いため含める
                if requested_scope == "game" then
                    -- Gameスコープの場合は、Game側のプラグインのみを含める
                    if comp_meta.owner_name == game_name then
                        should_add = true
                    end
                else
                    should_add = true 
                end
            end

            if should_add and comp_meta.root_path then
                -- refresh_modules.lua と同じ命名規則を使用: Type_DisplayName
                local pseudo_name = comp_meta.type .. "_" .. comp_meta.display_name
                if not pseudo_module_files[pseudo_name] then
                    pseudo_module_files[pseudo_name] = { root = comp_meta.root_path }
                end
            end
        end
    end

    -- 3. 登録された疑似モジュールのキャッシュを読み込み、ファイル/ディレクトリを追加（SQLiteのみ）
    if next(pseudo_module_files) then
        for pseudo_name, data in pairs(pseudo_module_files) do
            local pseudo_files = get_module_files_from_db(pseudo_name, data.root)
            local pseudo_dirs = get_module_dirs_from_db(pseudo_name, data.root)

            if pseudo_files then
              for category, files in pairs(pseudo_files) do
                local should_include = false
                
                if requested_mode then
                    if requested_mode == "config" then should_include = (category == "config")
                    elseif requested_mode == "shader" then should_include = (category == "shader")
                    elseif requested_mode == "programs" then should_include = (category == "source" or category == "programs")
                    elseif requested_mode == "source" then should_include = (category == "source")
                    end
                else
                    -- Legacy
                    should_include = true
                    local allow_programs = (requested_scope == "programs" or requested_scope == "full")
                    if category == "programs" and not allow_programs then should_include = false end
                    if requested_scope == "config" and category ~= "config" then should_include = false end
                end

                if should_include then
                  for _, file_path in ipairs(files) do
                    local add_file = true
                    if requested_mode == "shader" then
                        add_file = (file_path:match("%.usf$") or file_path:match("%.ush$"))
                    elseif requested_mode == "source" or requested_mode == "programs" then
                        if file_path:match("%.usf$") or file_path:match("%.ush$") then
                            add_file = false
                        end
                    end
                    
                    if add_file then
                        table.insert(merged_files_with_context, {
                          file_path = file_path, module_name = pseudo_name, module_root = data.root, category = category
                        })
                    end
                  end
                end
              end
            end
        end
    end

    local end_time = os.clock()
    log.info("core_files.get_files finished in %.4f seconds. Found %d files from %d modules (+ pseudo).",
      end_time - start_time, #merged_files_with_context, modules_processed)

    on_complete(true, merged_files_with_context)
  end)
end

-- (既存) モジュール単体のファイル取得
function M.get_files_for_module(module_name, on_complete)
  local log = uep_log.get()
  log.debug("core_files.get_files_for_module called for '%s'", module_name)
  local start_time = os.clock()

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("get_files_for_module: Failed to get project maps: %s", tostring(maps))
      return on_complete(false, "Failed to get project maps.")
    end

    local mod_meta = maps.all_modules_map[module_name]
    if not mod_meta then
      log.error("get_files_for_module: Module '%s' not found in project maps.", module_name)
      return on_complete(false, ("Module '%s' not found."):format(module_name))
    end

    local files_from_db = get_module_files_from_db(module_name, mod_meta.module_root)
    local module_files = {}

    if files_from_db then
      for category, files in pairs(files_from_db) do
        vim.list_extend(module_files, files)
      end
    end

    local end_time = os.clock()
    log.info("get_files_for_module for '%s' finished in %.4f seconds. Found %d files.",
         module_name, end_time - start_time, #module_files)

    on_complete(true, { files = module_files, module_meta = mod_meta })
  end)
end

function M.get_all_cached_items(opts, on_complete)
  local log = uep_log.get()
  opts = opts or {}
  local requested_scope = opts.scope or "full" -- デフォルトを広めに "full" に変更
  local deps_flag = opts.deps_flag or "--deep-deps"

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return on_complete(false, "Failed to get project maps.")
    end
    
    local all_modules_map = maps.all_modules_map
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name

    -- 1. 起点モジュールの決定 (get_filesと同じロジック)
    local seed_modules = {}
    if requested_scope == "game" then
      for n, m in pairs(all_modules_map) do if m.owner_name == game_name then seed_modules[n] = true end end
    elseif requested_scope == "engine" then
      for n, m in pairs(all_modules_map) do if m.owner_name == engine_name then seed_modules[n] = true end end
    elseif requested_scope == "runtime" then
      for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
    elseif requested_scope == "full" then
      for n, m in pairs(all_modules_map) do if m.type ~= "Program" then seed_modules[n] = true end end
    else -- Default Runtime
      for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
    end

    -- 2. 依存関係の解決
    local target_module_names = seed_modules
    if deps_flag ~= "--no-deps" and requested_scope ~= "full" then
        local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
        local modules_to_process = vim.tbl_keys(seed_modules)
        local processed = {}
        
        while #modules_to_process > 0 do
            local current = table.remove(modules_to_process)
            if not processed[current] then
                processed[current] = true
                target_module_names[current] = true
                local meta = all_modules_map[current]
                if meta and meta[deps_key] then
                    for _, dep in ipairs(meta[deps_key]) do
                         if not processed[dep] and all_modules_map[dep] then
                             table.insert(modules_to_process, dep)
                         end
                    end
                end
            end
        end
    end

    local items = {}
    local seen = {}
    
    -- 3. モジュールファイル/ディレクトリをSQLiteから収集
    for mod_name, _ in pairs(target_module_names) do
      local mod_meta = all_modules_map[mod_name]
      if mod_meta then
        local files_from_db = get_module_files_from_db(mod_name, mod_meta.module_root)
        local dirs_from_db = get_module_dirs_from_db(mod_name, mod_meta.module_root)
        if files_from_db then
          for _, list in pairs(files_from_db) do
            for _, path in ipairs(list) do
              if not seen[path] then
                table.insert(items, { path = path, type = "file" })
                seen[path] = true
              end
            end
          end
        end
        if dirs_from_db then
          for _, list in pairs(dirs_from_db) do
            for _, path in ipairs(list) do
              if not seen[path] then
                table.insert(items, { path = path, type = "directory" })
                seen[path] = true
              end
            end
          end
        end
      end
    end

    -- 4. 疑似モジュール (Config/Shaders) の収集もSQLiteのみ
    local add_game_pseudos = false
    local add_engine_pseudos = false

    if requested_scope == "full" then
      add_game_pseudos = true; add_engine_pseudos = true
    elseif requested_scope == "game" then
      add_game_pseudos = true
      if deps_flag ~= "--no-deps" then add_engine_pseudos = true end
    elseif requested_scope == "engine" then
      add_engine_pseudos = true
    else -- Runtime/Developer etc
      add_game_pseudos = true; add_engine_pseudos = true
    end

    if add_game_pseudos and maps.all_components_map then
      for _, comp in pairs(maps.all_components_map) do
        if comp.type == "Game" or comp.type == "Plugin" then
           local pseudo_name = comp.type .. "_" .. comp.display_name
           local pseudo_files = get_module_files_from_db(pseudo_name, comp.root_path)
           local pseudo_dirs = get_module_dirs_from_db(pseudo_name, comp.root_path)
           if pseudo_files then
            for _, l in pairs(pseudo_files) do
              for _, p in ipairs(l) do
                if not seen[p] then table.insert(items, {path=p, type="file"}) seen[p]=true end
              end
            end
           end
           if pseudo_dirs then
            for _, l in pairs(pseudo_dirs) do
              for _, p in ipairs(l) do
                if not seen[p] then table.insert(items, {path=p, type="directory"}) seen[p]=true end
              end
            end
           end
        end
      end
    end
    
    if add_engine_pseudos and maps.engine_root then
      local engine_pseudos = {
        { name = "_EngineConfig", root = fs.joinpath(maps.engine_root, "Engine", "Config") },
        { name = "_EngineShaders", root = fs.joinpath(maps.engine_root, "Engine", "Shaders") },
      }
      for _, p in ipairs(engine_pseudos) do
         local pseudo_files = get_module_files_from_db(p.name, p.root)
         local pseudo_dirs = get_module_dirs_from_db(p.name, p.root)
         if pseudo_files then
          for _, l in pairs(pseudo_files) do
            for _, f in ipairs(l) do
              if not seen[f] then table.insert(items, {path=f, type="file"}) seen[f]=true end
            end
          end
         end
         if pseudo_dirs then
          for _, l in pairs(pseudo_dirs) do
            for _, d in ipairs(l) do
              if not seen[d] then table.insert(items, {path=d, type="directory"}) seen[d]=true end
            end
          end
         end
      end
    end

    log.info("get_all_cached_items: Found %d items (Scope: %s, Deps: %s).", #items, requested_scope, deps_flag)
    on_complete(true, items)
  end)
end

return M
