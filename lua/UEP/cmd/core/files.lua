-- lua/UEP/cmd/core/files.lua
local module_cache = require("UEP.cache.module")
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")
local fs = require("vim.fs")

local M = {}

---
-- 指定されたスコープと依存関係フラグに基づいてファイルリストを取得する新しいコア関数
function M.get_files(opts, on_complete)
  local log = uep_log.get()
  local start_time = os.clock()
  opts = opts or {}
  local requested_scope = opts.scope or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"

  log.debug("core_files.get_files called with scope=%s, deps_flag=%s", requested_scope, deps_flag)

  -- STEP 1: プロジェクトの全体マップを取得
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("core_files.get_files: Failed to get project maps: %s", tostring(maps))
      return on_complete(false, "Failed to get project maps.")
    end

    local all_modules_map = maps.all_modules_map
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name

    -- STEP 2: 対象となるモジュールをフィルタリング
    local target_module_names = {}
    local seed_modules = {}
    
    -- 2a: スコープに基づいて起点モジュールを決定
    if requested_scope == "game" then
      for n, m in pairs(all_modules_map) do 
        if m.owner_name == game_name and m.location == "in_source" then 
          seed_modules[n] = true 
        end 
      end
    elseif requested_scope == "engine" then
      for n, m in pairs(all_modules_map) do
        if m.owner_name == engine_name then
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
                        if requested_scope == "game" or requested_scope == "engine" or requested_scope == "editor" or requested_scope == "full" then
                            if dep_meta.type and dep_meta.type ~= "Program" then
                                should_add = true
                            end
                        elseif requested_scope == "runtime" then 
                            should_add = (dep_meta.type == "Runtime")
                        elseif requested_scope == "developer" then 
                            should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer")
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

    -- STEP 3: 対象モジュールのキャッシュをロードしてファイルを集約
    local merged_files_with_context = {}
    local modules_processed = 0
    
    for mod_name, _ in pairs(target_module_names) do
      local mod_meta = all_modules_map[mod_name]
      if mod_meta and mod_meta.type ~= "Program" then
        local mod_cache_data = module_cache.load(mod_meta)
        if mod_cache_data and mod_cache_data.files then
          for category, files in pairs(mod_cache_data.files) do
            if category ~= "programs" then
              for _, file_path in ipairs(files) do
                table.insert(merged_files_with_context, {
                  file_path = file_path, module_name = mod_name, module_root = mod_meta.module_root, category = category
                })
              end
            end
          end
        elseif mod_cache_data == nil then
          log.warn("core_files.get_files: Module cache not found for '%s'. Run :UEP refresh!", mod_name)
        end
        modules_processed = modules_processed + 1
      end
    end

    -- STEP 4: スコープとDepsフラグに応じて、疑似モジュール(Plugin/Game/Engine)を追加
    local pseudo_module_files = {}

    -- 1. Engine の疑似モジュール (_EngineShaders 等)
    local add_engine_pseudos = false
    if deps_flag ~= "--no-deps" then
        if requested_scope == "engine" or requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" then
            add_engine_pseudos = true
        end
    end

    if add_engine_pseudos and maps.engine_root then
        pseudo_module_files._EngineShaders = { root=fs.joinpath(maps.engine_root, "Engine", "Shaders") }
        pseudo_module_files._EngineConfig  = { root=fs.joinpath(maps.engine_root, "Engine", "Config") }
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
                should_add = true 
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

    -- 3. 登録された疑似モジュールのキャッシュを読み込み、ファイルを追加
    if next(pseudo_module_files) then
        for pseudo_name, data in pairs(pseudo_module_files) do
            local pseudo_meta = { name = pseudo_name, module_root = data.root }
            local pseudo_cache = module_cache.load(pseudo_meta)
            
            if pseudo_cache and pseudo_cache.files then
                for category, files in pairs(pseudo_cache.files) do
                    if category ~= "programs" then -- "programs" カテゴリは除外
                        for _, file_path in ipairs(files) do
                            table.insert(merged_files_with_context, {
                                file_path = file_path, module_name = pseudo_name, module_root = data.root, category = category
                            })
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

        local mod_cache_data = module_cache.load(mod_meta)
        if not mod_cache_data then
            log.warn("get_files_for_module: Module cache not found for '%s'. Run :UEP refresh!", module_name)
            return on_complete(true, { files = {}, module_meta = mod_meta })
        end

        local module_files = {}
        if mod_cache_data.files then
            for category, files in pairs(mod_cache_data.files) do
                vim.list_extend(module_files, files)
            end
        end

        local end_time = os.clock()
        log.info("get_files_for_module for '%s' finished in %.4f seconds. Found %d files.",
                 module_name, end_time - start_time, #module_files)

        on_complete(true, { files = module_files, module_meta = mod_meta })
    end)
end

return M
