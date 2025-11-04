-- lua/UEP/cmd/core/files.lua (依存関係ロジック + 疑似モジュールロジック 修正版)

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
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps) -- line 25: コールバック開始
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
        if m.type ~= "Program" then -- ★ "Program" タイプのモジュールを除外
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
    end -- <<< if/elseif ブロック全体を閉じる end

    -- ▼▼▼ 修正: STEP 2b を丸ごと置き換え ▼▼▼
    
    -- 2b: 依存関係フラグに基づき、*プリ計算済みのリスト* を使ってモジュールを追加
    
    target_module_names = seed_modules -- 常に起点モジュールは含む
    
    if deps_flag == "--no-deps" then
        log.debug("Deps: --no-deps. Using seed modules only.")
        -- 何も追加しない
    
    else
        -- shallow または deep のキーを決定
        local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
        log.debug("Deps: %s. Using key: %s", deps_flag, deps_key)
        
        for mod_name, _ in pairs(seed_modules) do
            local mod_meta = all_modules_map[mod_name]
            if mod_meta and mod_meta[deps_key] then
                for _, dep_name in ipairs(mod_meta[deps_key]) do
                    local dep_meta = all_modules_map[dep_name]
                    if dep_meta then
                        
                        -- スコープに基づき、追加すべき依存モジュールか判定
                        local should_add = false

                        -- requested_scope が "game", "engine", "editor", "full" の場合、
                        -- 依存モジュールのタイプを寛容にチェックする (Program 以外はほぼ許可)
                        if requested_scope == "game" or requested_scope == "engine" or requested_scope == "editor" or requested_scope == "full" then
                            if dep_meta.type and dep_meta.type ~= "Program" then
                                -- "runtime", "developer", "editor", "uncookedonly" などをすべて許可
                                should_add = true
                            end
                        
                        -- requested_scope が "runtime", "developer" の場合は、厳格にチェック
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
    -- ▲▲▲ STEP 2b 置き換え完了 ▲▲▲

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
      
      -- ★ 念のため、ここで "Program" モジュールが紛れ込んでいないか再チェック
      if mod_meta and mod_meta.type ~= "Program" then
        local mod_cache_data = module_cache.load(mod_meta)
        if mod_cache_data and mod_cache_data.files then
          
          for category, files in pairs(mod_cache_data.files) do
            if category ~= "programs" then -- ★ "programs" カテゴリをスキップ
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
      else
        if mod_meta and mod_meta.type == "Program" then
           log.trace("core_files.get_files: Skipping Program module: %s", mod_name)
        else
           log.warn("core_files.get_files: Module meta not found for '%s' during aggregation.", mod_name)
        end
      end
    end

    -- ▼▼▼ 修正: STEP 4 を "deps_flag" を考慮するよう修正 ▼▼▼
    
    -- STEP 4: スコープとDepsフラグに応じて、疑似モジュール(Config/Shaders)を追加
    
    -- 1. このスコープで Game / Engine の疑似モジュールを追加すべきか判定
    local add_game_pseudos = false
    local add_engine_pseudos = false

    if deps_flag ~= "--no-deps" then
        -- --no-deps 以外の場合、スコープに応じて疑似モジュールを追加
        if requested_scope == "game" then
            add_game_pseudos = true
        elseif requested_scope == "engine" then
            add_engine_pseudos = true
        elseif requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" or requested_scope == "full" then
            add_game_pseudos = true
            add_engine_pseudos = true
        end
    end

    local pseudo_module_files = {}
    if add_engine_pseudos and maps.engine_root then
        pseudo_module_files._EngineShaders = { root=fs.joinpath(maps.engine_root, "Engine", "Shaders") }
        pseudo_module_files._EngineConfig  = { root=fs.joinpath(maps.engine_root, "Engine", "Config") }
    end
    if add_game_pseudos and maps.project_root then
        pseudo_module_files._GameShaders   = { root=fs.joinpath(maps.project_root, "Shaders") }
        pseudo_module_files._GameConfig    = { root=fs.joinpath(maps.project_root, "Config") }
    end

    -- 2. 登録された疑似モジュールのキャッシュを読み込み、ファイルを追加
    if next(pseudo_module_files) then
        for pseudo_name, data in pairs(pseudo_module_files) do
            local pseudo_meta = { name = pseudo_name, module_root = data.root }
            local pseudo_cache = module_cache.load(pseudo_meta)
            
            if pseudo_cache and pseudo_cache.files then
                for category, files in pairs(pseudo_cache.files) do
                    if category ~= "programs" then -- ★ "programs" カテゴリは除外
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
    -- ▲▲▲ 修正完了 ▲▲▲

    local end_time = os.clock()
    log.info("core_files.get_files finished in %.4f seconds. Found %d files from %d modules (+ pseudo if %s).",
      end_time - start_time, #merged_files_with_context, modules_processed, deps_flag)

    on_complete(true, merged_files_with_context)

  end) -- line 154?: コールバック関数の終わり
end -- M.get_files の終わり

-- (get_files_for_module は変更なし)
function M.get_files_for_module(module_name, on_complete)
    local log = uep_log.get()
    log.debug("core_files.get_files_for_module called for '%s'", module_name)
    local start_time = os.clock()

    -- STEP 1: プロジェクトマップを取得してモジュールメタデータを検索
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

        -- STEP 2: モジュールキャッシュをロード
        local mod_cache_data = module_cache.load(mod_meta)
        if not mod_cache_data then
            log.warn("get_files_for_module: Module cache not found for '%s'. Run :UEP refresh!", module_name)
            -- キャッシュがなくてもエラーではないので、空リストを返す
            return on_complete(true, { files = {}, module_meta = mod_meta })
        end

        -- STEP 3: キャッシュ内の全ファイルパスを集約
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
