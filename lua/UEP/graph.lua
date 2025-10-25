-- lua/UEP/graph.lua をこの内容で完全に置き換える

local uep_log = require("UEP.logger")
local M = {}

-- (build_graph と resolve_single_module_deep は変更なし)
local function build_graph(modules_for_graph)
  local graph = { nodes = {}, deps = {}, rdeps = {} }
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

local function resolve_single_module_deep(module_name, graph, memo, path, warned_cycles)
  if memo[module_name] then return memo[module_name] end
  if path[module_name] then
    if not warned_cycles[module_name] then
      local cycle_path_str = table.concat(vim.tbl_keys(path), " -> ") .. " -> " .. module_name
      uep_log.get().info("Circular dependency detected. Path: %s", cycle_path_str)
      warned_cycles[module_name] = true
    end
    return {}
  end
  path[module_name] = true
  local deep_deps = {}
  for direct_dep in pairs(graph.deps[module_name]) do
    deep_deps[direct_dep] = true
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
-- 全モジュールの依存関係を解決するメインAPI (簡略版)
function M.resolve_all_dependencies(all_modules_meta)
  if not all_modules_meta or not next(all_modules_meta) then
    uep_log.get().warn("graph.lua: Received no modules to process. Returning empty map.")
    return {}, nil
  end

  -- STEP 1: 受け取った生のデータから、直接グラフを構築する
  local graph = build_graph(all_modules_meta)

  local memo = {}
  local warned_cycles = {}
  local final_result = {}

  -- STEP 2: 全モジュールをループし、依存関係を解決してクリーンな形式で格納する
  for name, original_meta in pairs(all_modules_meta) do
    local shallow_deps_list = {}
    if graph.deps[name] then
      for dep_name in pairs(graph.deps[name]) do table.insert(shallow_deps_list, dep_name) end
    end
    table.sort(shallow_deps_list)

    local deep_deps_set = resolve_single_module_deep(name, graph, memo, {}, warned_cycles)
    local deep_deps_list = vim.tbl_keys(deep_deps_set)
    table.sort(deep_deps_list)

    final_result[name] = {
      name = original_meta.name,
      path = original_meta.path,
      module_root = original_meta.module_root,
      category = original_meta.category,
      location = original_meta.location,
      shallow_dependencies = shallow_deps_list,
      deep_dependencies = deep_deps_list,
      type = original_meta.type,           -- ★ type をコピー
      owner_name = original_meta.owner_name -- ★ owner_name もコピー
    }
  end

  return final_result, nil
end

return M
