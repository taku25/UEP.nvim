-- lua/UEP/cmd/core/files.lua (構文エラー再々修正版 - 完全版)

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
    -- (if/elseif ブロック - 変更なし)
-- 2a: スコープに基づいて起点モジュールを決定
    if requested_scope == "game" then
        for n, m in pairs(all_modules_map) do if m.owner_name == game_name then seed_modules[n] = true end end
    elseif requested_scope == "engine" then
        for n, m in pairs(all_modules_map) do if m.owner_name == engine_name then seed_modules[n] = true end end
    elseif requested_scope == "runtime" then
        for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
    elseif requested_scope == "developer" then
        for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
    elseif requested_scope == "editor" then
      for n, m in pairs(all_modules_map) do
        if m.type and m.type ~= "Program" then
          local ct = m.type:match("^%s*(.-)%s*$"):lower()
          if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then
            seed_modules[n] = true
          end -- <<< 内側の if を閉じる end
        end -- <<< ★★★ ここに end が必要でした ★★★ (if m.type... を閉じる end)
      end -- <<< for ループを閉じる end
    elseif requested_scope == "full" then
      for n,_ in pairs(all_modules_map) do
        seed_modules[n] = true
      end
    else -- Unknown scope defaults to runtime
      requested_scope = "runtime"
      for n, m in pairs(all_modules_map) do
        if m.type == "Runtime" then
          seed_modules[n] = true
        end
      end
    end -- <<< if/elseif ブロック全体を閉じる end

    -- ▼▼▼ 2b: 依存関係フラグに基づく依存モジュール追加 (end の位置を最終確認) ▼▼▼
    if deps_flag == "--no-deps" or requested_scope == "full" then
      target_module_names = seed_modules
    else
      local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
      local modules_to_process = vim.tbl_keys(seed_modules)
      local processed = {}

      while #modules_to_process > 0 do                       --[[ WHILE Start ]]
        local current_name = table.remove(modules_to_process)
        if not processed[current_name] then                --[[ IF 1 Start ]]
          processed[current_name] = true
          target_module_names[current_name] = true
          local current_meta = all_modules_map[current_name]
          if current_meta and current_meta[deps_key] then --[[ IF 2 Start ]]
            for _, dep_name in ipairs(current_meta[deps_key]) do --[[ FOR Start ]]
              if not processed[dep_name] then         --[[ IF 3 Start ]]
                local dep_meta = all_modules_map[dep_name]
                if dep_meta then                    --[[ IF 4 Start ]]
                  local should_add = false
                  --[[ IF 5 Start (Scope Check) ]]
                  if requested_scope == "game" then should_add = (dep_meta.owner_name == game_name)
                  elseif requested_scope == "engine" then should_add = (dep_meta.owner_name == engine_name)
                  elseif requested_scope == "runtime" then should_add = (dep_meta.type == "Runtime")
                  elseif requested_scope == "developer" then should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer")
                  elseif requested_scope == "editor" then
                    if dep_meta.type and dep_meta.type ~= "Program" then --[[ IF 6 Start ]]
                      local ct = dep_meta.type:match("^%s*(.-)%s*$"):lower()
                      should_add = ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly"
                    end                                --[[ IF 6 End ]]
                  end                                    --[[ IF 5 End (Scope Check) ]]
                  if should_add then                     --[[ IF 7 Start ]]
                    table.insert(modules_to_process, dep_name)
                  end                                    --[[ IF 7 End ]]
                end                                        --[[ IF 4 End ]]
              end                                            --[[ IF 3 End ]]
            end                                                --[[ FOR End ]]
          end                                                    --[[ IF 2 End ]]
        end                                                        --[[ IF 1 End ]]
      end                                                            --[[ WHILE End ]]
    end -- <<< if deps_flag ... else の end
    -- ▲▲▲ 修正ここまで ▲▲▲

    local filtered_module_count = vim.tbl_count(target_module_names)
    log.debug("core_files.get_files: Filtered down to %d modules for scope=%s, deps=%s", filtered_module_count, requested_scope, deps_flag)
    if filtered_module_count == 0 then
      log.warn("core_files.get_files: No modules matched the filter.")
      return on_complete(true, {})
    end

    -- STEP 3: 対象モジュールのキャッシュをロードしてファイルを集約
    local merged_files_with_context = {}
    local modules_processed = 0
    -- (for ループ - 変更なし)
    for mod_name, _ in pairs(target_module_names) do
      local mod_meta = all_modules_map[mod_name]
      if mod_meta then
        local mod_cache_data = module_cache.load(mod_meta)
        if mod_cache_data and mod_cache_data.files then
          for category, files in pairs(mod_cache_data.files) do
            for _, file_path in ipairs(files) do
              table.insert(merged_files_with_context, {
                file_path = file_path, module_name = mod_name, module_root = mod_meta.module_root, category = category
              })
            end
          end
        elseif mod_cache_data == nil then
          log.warn("core_files.get_files: Module cache not found for '%s'. Run :UEP refresh!", mod_name)
        end
        modules_processed = modules_processed + 1
      else
        log.warn("core_files.get_files: Module meta not found for '%s' during aggregation.", mod_name)
      end
    end

    -- STEP 4: Full スコープの場合、疑似モジュールのファイルも追加
    -- (if ブロック - 変更なし)
    if requested_scope == "full" and maps.project_root and maps.engine_root then
      local pseudo_module_files = {
        _EngineShaders = { root=fs.joinpath(maps.engine_root, "Engine", "Shaders") },
        _EngineConfig  = { root=fs.joinpath(maps.engine_root, "Engine", "Config") },
        _GameShaders   = { root=fs.joinpath(maps.project_root, "Shaders") },
        _GameConfig    = { root=fs.joinpath(maps.project_root, "Config") },
      }
      for pseudo_name, data in pairs(pseudo_module_files) do
        local pseudo_meta = { name = pseudo_name, module_root = data.root }
        local pseudo_cache = module_cache.load(pseudo_meta)
        if pseudo_cache and pseudo_cache.files then
          for category, files in pairs(pseudo_cache.files) do
            for _, file_path in ipairs(files) do
              table.insert(merged_files_with_context, {
                file_path = file_path, module_name = pseudo_name, module_root = data.root, category = category
              })
            end
          end
        end
      end
    end

    local end_time = os.clock()
    log.info("core_files.get_files finished in %.4f seconds. Found %d files from %d modules (+ pseudo if Full).",
      end_time - start_time, #merged_files_with_context, modules_processed)

    on_complete(true, merged_files_with_context)

  end) -- line 154?: コールバック関数の終わり
end -- M.get_files の終わり

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
-- M.get_files_for_single_module = function(...) end

return M
