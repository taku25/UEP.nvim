-- lua/UEP/cmd/core/derived.lua (スコープ・モジュールキャッシュ対応版)

local core_utils = require("UEP.cmd.core.utils")
-- local files_cache_manager = require("UEP.cache.files") -- 旧キャッシュ (削除)
local module_cache = require("UEP.cache.module") -- ★ モジュールキャッシュを使用
local uep_log = require("UEP.logger")
local fs = require("vim.fs") -- ★ fs を require (疑似モジュール用)

local M = {}

---
-- プロジェクト内のC++クラス/構造体情報をスコープと依存関係に基づいて収集する (新版)
-- @param opts table
--   opts.scope (string, optional): "Game", "Engine", "Runtime"(default), "Developer", "Editor", "Full"
--   opts.deps_flag (string, optional): "--deep-deps"(default), "--shallow-deps", "--no-deps"
-- @param on_complete function(symbol_list | nil)
--        symbol_list = { { display=..., class_name=..., base_class=..., file_path=..., filename=..., symbol_type=... }, ... }
function M.get_all_classes(opts, on_complete)
  local log = uep_log.get()
  local start_time = os.clock()
  opts = opts or {}
  local requested_scope = opts.scope or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"

  log.debug("derived.get_all_classes called with scope=%s, deps_flag=%s", requested_scope, deps_flag)

  -- STEP 1: プロジェクト全体のマップ情報を取得
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps) -- line 28: コールバック開始
    if not ok then
      log.error("derived.get_all_classes: Failed to get project maps: %s", tostring(maps))
      if on_complete then on_complete(nil) end
      return
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
      for n, m in pairs(all_modules_map) do --[[ FOR Start ]]
        if m.type and m.type ~= "Program" then --[[ IF 1 Start ]]
          local ct = m.type:match("^%s*(.-)%s*$"):lower()
          if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then --[[ IF 2 Start ]]
            seed_modules[n] = true
          end --[[ IF 2 End ]]
        end --[[ IF 1 End ]]
      end --[[ ★★★ ここに FOR ループを閉じる end が必要でした ★★★ ]]
    elseif requested_scope == "full" then
      for n,_ in pairs(all_modules_map) do seed_modules[n] = true end
    else -- Unknown scope defaults to runtime
      requested_scope = "runtime"
      for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
    end -- <<< if/elseif ブロック全体を閉じる end

    -- ▼▼▼ 2b: 依存関係フラグに基づく依存モジュール追加 (end の数を修正) ▼▼▼
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
                    -- ★★★ ここに end が必要でした (if/elseif scope...) ★★★
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
    log.debug("derived.get_all_classes: Filtered down to %d modules for scope=%s, deps=%s", filtered_module_count, requested_scope, deps_flag)
    if filtered_module_count == 0 then
      log.warn("derived.get_all_classes: No modules matched the filter.")
      if on_complete then on_complete({}) end
      return
    end

    -- STEP 3: 対象モジュールのキャッシュをロードし、シンボル情報を収集
    local all_symbols = {}
    local modules_processed = 0
    -- (for ループ - 変更なし)
    for mod_name, _ in pairs(target_module_names) do
      local mod_meta = all_modules_map[mod_name]
      if mod_meta then
        local mod_cache_data = module_cache.load(mod_meta)
        if mod_cache_data and mod_cache_data.header_details then
          for file_path, details in pairs(mod_cache_data.header_details) do
            if details.classes then
              for _, symbol_info in ipairs(details.classes) do
                table.insert(all_symbols, {
                  display = symbol_info.class_name, class_name = symbol_info.class_name, base_class = symbol_info.base_class, file_path = file_path, filename = file_path, symbol_type = symbol_info.symbol_type or "class"
                })
              end
            end
          end
        elseif mod_cache_data == nil then
          log.trace("derived.get_all_classes: Module cache not found for '%s'. Skipping.", mod_name)
        end
        modules_processed = modules_processed + 1
      else
        log.warn("derived.get_all_classes: Module meta not found for '%s' during aggregation.", mod_name)
      end
    end

    -- STEP 4: Full スコープの場合、疑似モジュールのシンボルも追加
    -- (if ブロック - 変更なし)
    if requested_scope == "full" and maps.project_root and maps.engine_root then
      -- ▼▼▼ ここが省略されていた箇所です ▼▼▼
      local pseudo_module_files = {
        _EngineShaders = { root=fs.joinpath(engine_root, "Engine", "Shaders"), files={}, dirs={} },
        _EngineConfig  = { root=fs.joinpath(engine_root, "Engine", "Config"), files={}, dirs={} },
        _GameShaders   = { root=fs.joinpath(project_root, "Shaders"), files={}, dirs={} },
        _GameConfig    = { root=fs.joinpath(project_root, "Config"), files={}, dirs={} },
        -- _GameContent は除外
      }
      -- ▲▲▲ ここまで ▲▲▲
      for pseudo_name, data in pairs(pseudo_module_files) do
        local pseudo_meta = { name = pseudo_name, module_root = data.root }
        local pseudo_cache = module_cache.load(pseudo_meta)
        if pseudo_cache and pseudo_cache.header_details then
          for file_path, details in pairs(pseudo_cache.header_details) do
            if details.classes then
              for _, symbol_info in ipairs(details.classes) do
                table.insert(all_symbols, {
                  display = symbol_info.class_name, class_name = symbol_info.class_name, base_class = symbol_info.base_class, file_path = file_path, filename = file_path, symbol_type = symbol_info.symbol_type or "class"
                })
              end
            end
          end
        end
      end
    end

    local end_time = os.clock()
    log.info("derived.get_all_classes finished in %.4f seconds. Found %d symbols from %d modules (+ pseudo if Full).",
      end_time - start_time, #all_symbols, modules_processed)

    -- STEP 5: ソートして完了コールバックを呼ぶ
    table.sort(all_symbols, function(a, b) local na = a.class_name or ""; local nb = b.class_name or ""; return na < nb end)
    if on_complete then on_complete(all_symbols) end

  end) -- line ?: コールバック関数の終わり
end -- M.get_all_classes の終わり

---
-- 指定された基底クラスのすべての子孫クラス（孫以降も含む）を再帰的に検索する
-- 注意: この関数は内部で get_all_classes を呼ぶため、スコープ/Deps は get_all_classes に依存
-- @param base_class_name string 基底クラス名
-- @param opts table (get_all_classes に渡すスコープ/Deps指定)
-- @param on_complete function(derived_list | nil)
function M.get_derived_classes(base_class_name, opts, on_complete)
  -- ★ opts を get_all_classes に渡す
  M.get_all_classes(opts, function(all_symbols_data)
    if not all_symbols_data then
      if on_complete then on_complete(nil) end
      return
    end

    -- (以降の再帰検索ロジックは変更なし)
    local parent_to_children = {}
    for _, symbol_data in ipairs(all_symbols_data) do
      if symbol_data.base_class then
        parent_to_children[symbol_data.base_class] = parent_to_children[symbol_data.base_class] or {}
        table.insert(parent_to_children[symbol_data.base_class], symbol_data)
      end
    end
    local derived_symbols = {}
    local visited = {}
    local function find_recursively(current_base_name)
      if visited[current_base_name] then return end
      visited[current_base_name] = true
      local direct_children = parent_to_children[current_base_name]
      if direct_children then
        for _, child_info in ipairs(direct_children) do
          table.insert(derived_symbols, child_info)
          find_recursively(child_info.class_name)
        end
      end
    end
    find_recursively(base_class_name)
    table.sort(derived_symbols, function(a, b) return (a.class_name or "") < (b.class_name or "") end)
    if on_complete then on_complete(derived_symbols) end
  end)
end

---
-- 指定されたクラス/構造体の継承チェーンを検索する
-- 注意: この関数は内部で get_all_classes を呼ぶため、スコープ/Deps は get_all_classes に依存
-- @param child_symbol_name string 起点となるシンボル名
-- @param opts table (get_all_classes に渡すスコープ/Deps指定)
-- @param on_complete function(chain_list | nil)
function M.get_inheritance_chain(child_symbol_name, opts, on_complete)
  -- ★ opts を get_all_classes に渡す
  M.get_all_classes(opts, function(all_symbols_data)
    if not all_symbols_data then
      if on_complete then on_complete(nil) end
      return
    end

    -- (以降の継承チェーン検索ロジックは変更なし)
    local symbol_map = {}
    for _, symbol_info in ipairs(all_symbols_data) do
      symbol_map[symbol_info.class_name] = symbol_info
    end
    local inheritance_chain = {}
    local current_symbol_name = child_symbol_name
    local visited = {}
    while current_symbol_name and not visited[current_symbol_name] do
      visited[current_symbol_name] = true
      local current_symbol_info = symbol_map[current_symbol_name]
      if current_symbol_info and current_symbol_info.base_class then
        local parent_info = symbol_map[current_symbol_info.base_class]
        if parent_info then
          table.insert(inheritance_chain, parent_info)
          current_symbol_name = parent_info.class_name
        else break end
      else break end
    end
    if on_complete then on_complete(inheritance_chain) end
  end)
end

return M
