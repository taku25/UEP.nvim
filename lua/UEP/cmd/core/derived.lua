-- lua/UEP/cmd/core/derived.lua (スコープのデフォルトを 'Full' に設定)

local core_utils = require("UEP.cmd.core.utils")
local files_cache_manager = require("UEP.cache.files")
local uep_log = require("UEP.logger")

local M = {}

---
-- プロジェクト内のC++クラス/構造体情報を依存関係スコープに基づいて収集する
-- @param opts table
--   opts.scope (string, optional): "Game", "Engine", または "Full" (デフォルト)
--   opts.deps_flag (string, optional): "--no-deps" または "--all-deps" (Fullの場合は無視)
-- @param on_complete function(symbol_list | nil)
function M.get_all_classes(opts, on_complete)
  opts = opts or {}
  -- ▼▼▼【重要修正】デフォルトスコープを "Editor" に設定 ▼▼▼
  local scope = opts.scope or "Editor"
  local deps_flag = opts.deps_flag or "--no-deps"
  -- ▲▲▲ ここまで ▲▲▲
  local log = uep_log.get()

  log.debug("get_all_classes called with scope=%s, deps_flag=%s", scope, deps_flag)

  -- 1. プロジェクト全体のマップ情報を取得
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("get_all_classes: Failed to get project maps: %s", tostring(maps))
      if on_complete then on_complete(nil) end
      return
    end

    local all_modules_map = maps.all_modules_map
    local module_to_component_name = maps.module_to_component_name
    local all_components_map = maps.all_components_map

    local required_modules_set = {}
    local components_to_scan = {}
    local root_component = nil
    
    -- 検索済みコンポーネントを追跡するためのセット
    local components_added = {}
    local function add_component(comp_data)
        if comp_data and not components_added[comp_data.name] then
            components_to_scan[comp_data.name] = comp_data
            components_added[comp_data.name] = true
        end
    end

    if scope == "Editor" then
      -- ▼▼▼【Editorスコープ】Game, Engine, Pluginをすべてスキャン対象とする ▼▼▼
      log.info("Editor scope detected. Scanning ALL components.")
      
      -- Game, Engine, Plugin の全コンポーネントをスキャン対象に追加
      for _, component in pairs(all_components_map) do
        add_component(component)
      end
    
    elseif scope == "Game" or scope == "Engine" then
      -- ▼▼▼【Game/Engineスコープ】依存関係でフィルタリング (既存ロジック) ▼▼▼
      for _, component in pairs(all_components_map) do
        if component.type == scope then
          root_component = component
          break
        end
      end

      if root_component and root_component.modules then
        for mod_name, _ in pairs(root_component.modules) do
          required_modules_set[mod_name] = true
          local mod_data = all_modules_map[mod_name]
          if mod_data then
            local deps_key = (deps_flag == "--all-deps") and "deep_dependencies" or "shallow_dependencies"
            for _, dep_name in ipairs(mod_data[deps_key] or {}) do
              required_modules_set[dep_name] = true
            end
          end
        end

        -- required_modules_set に基づいてスキャン対象コンポーネントを決定
        for mod_name, _ in pairs(required_modules_set) do
          local comp_name = module_to_component_name[mod_name]
          if comp_name then
            add_component(all_components_map[comp_name])
          end
        end
      else
          log.warn("get_all_classes: Could not find root component for scope '%s'. Returning empty list.", scope)
          if on_complete then on_complete({}) end
          return
      end
    else
        -- 不明なスコープはエラー
        log.error("Invalid scope '%s' provided. Must be 'Game', 'Engine', or 'Editor'.", scope)
        if on_complete then on_complete(nil) end
        return
    end

    -- 3. 対象コンポーネントのキャッシュからシンボル情報を収集 (以下、変更なし)
    local all_symbols = {}
    log.debug("Scanning %d components for symbols based on scope=%s, deps_flag=%s",
              vim.tbl_count(components_to_scan), scope, deps_flag)
              
    -- ... (以下、シンボル収集ロジックを続ける) ...
    for comp_name, component in pairs(components_to_scan) do
      local files_cache = files_cache_manager.load_component_cache(component)
      -- ... (以下、シンボルを all_symbols に詰めるロジックは変更なし) ...
      if files_cache and files_cache.header_details then
        for file_path, details in pairs(files_cache.header_details) do
          if details.classes then
            for _, symbol_info in ipairs(details.classes) do
              table.insert(all_symbols, {
                display = symbol_info.class_name,
                class_name = symbol_info.class_name,
                base_class = symbol_info.base_class,
                file_path = file_path,
                filename = file_path,
                symbol_type = symbol_info.symbol_type,
              })
            end
          end
        end
      end
    end

    log.info("Found %d symbols for scope=%s, deps_flag=%s", #all_symbols, scope, deps_flag)
    -- ... (ソートして on_complete を呼ぶ) ...
    table.sort(all_symbols, function(a, b)
        local name_a = a.class_name or ""; local name_b = b.class_name or ""
        return name_a < name_b
    end)
    if on_complete then on_complete(all_symbols) end
  end)
end

---
-- 指定された基底クラスのすべての子孫クラス（孫以降も含む）を再帰的に検索する
-- 注意: この関数は現在、依存関係スコープを考慮しません。全シンボルから検索します。
-- @param base_class_name string 基底クラス名
-- @param on_complete function(derived_list | nil)
function M.get_derived_classes(base_class_name, on_complete)
  -- 常に全シンボルを取得して処理 (opts={})
  M.get_all_classes({}, function(all_symbols_data)
    if not all_symbols_data then
      if on_complete then on_complete(nil) end
      return
    end

    -- 親から直接の子への関係をマップする（以下、ロジックは変更なし）
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
-- 注意: この関数は現在、依存関係スコープを考慮しません。全シンボルから検索します。
-- @param child_symbol_name string 起点となるシンボル名
-- @param on_complete function(chain_list | nil)
function M.get_inheritance_chain(child_symbol_name, on_complete)
  -- 常に全シンボルを取得して処理 (opts={})
  M.get_all_classes({}, function(all_symbols_data)
    if not all_symbols_data then
      if on_complete then on_complete(nil) end
      return
    end

    -- クラス名をキーとするマップを作成（以下、ロジックは変更なし）
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
        else
          break
        end
      else
        break
      end
    end
    if on_complete then on_complete(inheritance_chain) end
  end)
end


return M
