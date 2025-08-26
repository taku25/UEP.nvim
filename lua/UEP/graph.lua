-- lua/UEP/graph.lua (循環参照の警告を抑制・改善した最終版)
-- 循環参照の警告を、各サイクルの起点ごとに一度しか表示しないように改良。
-- また、警告メッセージに循環パスを含めることで、よりデバッグしやすくする。

local uep_log       = require("UEP.logger")
local M = {}

---
-- モジュール情報の軽量なテーブルから依存関係グラフを構築する内部関数
-- @param modules_for_graph table { [name] = { dependencies = { public={}, private={} } } }
-- @return table graph { nodes, deps, rdeps }
--
local function build_graph(modules_for_graph)
  local graph = {
    nodes = {}, -- { [name] = true }
    deps = {},  -- { [name] = { [dep_name] = true } }
    rdeps = {}, -- { [name] = { [rdep_name] = true } }
  }
  for name, _ in pairs(modules_for_graph) do
    graph.nodes[name] = true
    graph.deps[name] = {}
    graph.rdeps[name] = {}
  end
  for name, meta in pairs(modules_for_graph) do
    local all_deps = {}
    if meta.dependencies then
      for _, dep_name in ipairs(meta.dependencies.public or {}) do all_deps[dep_name] = true end
      for _, dep_name in ipairs(meta.dependencies.private or {}) do all_deps[dep_name] = true end
    end
    for dep_name, _ in pairs(all_deps) do
      if graph.nodes[dep_name] then
        graph.deps[name][dep_name] = true
        graph.rdeps[dep_name][name] = true
      end
    end
  end
  return graph
end

---
-- 特定のモジュールの推移的依存関係を再帰的に解決するヘルパー関数
-- @param module_name string 開始モジュール
-- @param graph table build_graphが生成したグラフ
-- @param memo table 計算結果を保存するメモ化テーブル
-- @param path table 循環参照を検出するためのパス追跡テーブル
-- @param warned_cycles table 既に警告した循環参照の起点を記録するテーブル
-- @return table { [dep_name] = true }
--
local function resolve_single_module_deep(module_name, graph, memo, path, warned_cycles)

  if memo[module_name] then
    return memo[module_name]
  end

  if path[module_name] then
    --- ★ 変更点 1: 警告を一度だけ出すようにする ---
    if not warned_cycles[module_name] then
      -- どのパスで循環したか、より詳細な情報をログに出す
      local cycle_path_str = table.concat(vim.tbl_keys(path), " -> ") .. " -> " .. module_name
      uep_log.get().info("Circular dependency detected. Path: %s", cycle_path_str)
      warned_cycles[module_name] = true -- この起点からの警告はもう出さない
    end
    return {}
  end

  path[module_name] = true
  local deep_deps = {}

  for direct_dep in pairs(graph.deps[module_name]) do
    deep_deps[direct_dep] = true
    --- ★ 変更点 2: `warned_cycles` を再帰呼び出しに渡す ---
    local transitive_deps = resolve_single_module_deep(direct_dep, graph, memo, path, warned_cycles)
    for transitive_dep in pairs(transitive_deps) do
      deep_deps[transitive_dep] = true
    end
  end

  path[module_name] = nil
  memo[module_name] = deep_deps
  return deep_deps
end


---
-- 全モジュールの依存関係を解決するメインAPI
--
-- ★変更点1: 関数の引数に progress を追加
function M.resolve_all_dependencies(primary_modules, secondary_modules, progress)
  uep_log.get().info("Resolving dependencies for %d primary modules...", vim.tbl_count(primary_modules))

  local all_modules_for_graph = {}
  for name, meta in pairs(primary_modules) do
    all_modules_for_graph[name] = { dependencies = meta.dependencies }
  end
  -- 2. Engineモジュールをグラフ構築用テーブルに追加 (ここを修正)
  if secondary_modules then
    for name, meta in pairs(secondary_modules) do
      if not all_modules_for_graph[name] then
        -- ★★★ ここからが修正点 ★★★
        -- キャッシュされたモジュールは `shallow_dependencies` を持っている。
        -- これを使ってグラフ情報を再構築する。
        all_modules_for_graph[name] = {
          dependencies = {
            -- public/privateの区別はないので、全てpublicとして扱う
            public = meta.shallow_dependencies or {},
            private = {},
          }
        }
        -- ★★★ ここまでが修正点 ★★★
      end
    end
  end

  local graph = build_graph(all_modules_for_graph)
  uep_log.get().debug("Dependency graph built with %d nodes.", vim.tbl_count(graph.nodes))

  local memo = {}
  local warned_cycles = {}
  local final_result = {}

  -- ★変更点2: 進捗報告の準備
  local total_modules = vim.tbl_count(primary_modules)
  local processed_count = 0
  -- refresh.luaで定義済みのステージ名 "resolve_deps" をここでも使う
  if progress then
    progress:stage_define("resolve_deps", total_modules)
    progress:stage_update("resolve_deps", 0, "Starting dependency resolution...")
  end

  for name, original_meta in pairs(primary_modules) do
    -- ★変更点3: ループの最初で進捗を更新
    processed_count = processed_count + 1
    -- 毎回更新すると少し重いので、5モジュールごとなどに間引くとより効率的
    if progress and (processed_count % 5 == 0 or processed_count == total_modules) then
      progress:stage_update("resolve_deps", processed_count, ("Resolving: %s"):format(name))
      -- UIをブロックしないように、ここでもyieldするのが非常に効果的
      coroutine.yield()
    end

    local shallow_deps_list = {}
    for dep_name in pairs(graph.deps[name] or {}) do
      table.insert(shallow_deps_list, dep_name)
    end
    table.sort(shallow_deps_list)

    local deep_deps_set = resolve_single_module_deep(name, graph, memo, {}, warned_cycles)
    local deep_deps_list = {}
    for dep_name in pairs(deep_deps_set) do
      table.insert(deep_deps_list, dep_name)
    end
    table.sort(deep_deps_list)

    final_result[name] = {
      name = original_meta.name, path = original_meta.path,
      module_root = original_meta.module_root, category = original_meta.category,
      location = original_meta.location, shallow_dependencies = shallow_deps_list,
      deep_dependencies = deep_deps_list,
    }
  end

  uep_log.get().info("Dependency resolution complete.")
  return final_result, nil
end

return M
