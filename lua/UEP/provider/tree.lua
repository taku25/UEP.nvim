-- lua/UEP/provider/tree.lua (遅延読み込み対応版)

local unl_context = require("UNL.context")
local uep_log = require("UEP.logger").get()

-------------------------------------------------
-- ツリーモデル構築ヘルパー関数
-- (neo-tree-unl.nvimから移植)
-------------------------------------------------
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
      local new_path = vim.fs.joinpath(current_path, name)
      local node_type = "file"
      local children_nodes = nil

      local extra_data = {}

      if next(content) then
        node_type = "directory"
        hierarchy_data = table_to_nodes(content, new_path)
        extra_data.is_loaded = false -- ディレクトリは未ロード状態
      end
      extra_data.hierarchy = hierarchy_data
      -- ▼▼▼ 変更点 1: 'children' の代わりに 'extra.hierarchy' を使用 ▼▼▼
      -- これにより、neo-treeが直接子ノードとして認識するのを防ぎます。
      table.insert(nodes, {
        id = new_path, name = name, path = new_path, type = node_type,
        extra = extra_data,
      })
      -- ▲▲▲ 変更ここまで ▲▲▲
    end
    table.sort(nodes, function(a, b) return a.name < b.name end)
    return nodes
  end

  return table_to_nodes(root, root_path)
end

local function build_hierarchy_nodes(modules_meta, files_by_module)
  -- ▼▼▼ 変更点 2: 初期ノードの 'children' を 'extra.hierarchy' に変更 ▼▼▼
  local root_nodes = {
    Game = { id = "category_Game", name = "Game", type = "directory", extra = { uep_type = "category", hierarchy = {}, is_loaded = false } },
    Plugins = { id = "category_Plugins", name = "Plugins", type = "directory", extra = { uep_type = "category", hierarchy = {}, is_loaded = false } },
    Engine = { id = "category_Engine", name = "Engine", type = "directory", extra = { uep_type = "category", hierarchy = {}, is_loaded = false } },
  }
  -- ▲▲▲ 変更ここまで ▲▲▲
  local plugin_nodes = {}
  for name, meta in pairs(modules_meta) do
    if meta.module_root then
      local module_files = files_by_module[name] or {}
      local file_tree = build_fs_tree_from_flat_list(module_files, meta.module_root)
      -- ▼▼▼ 変更点 3: モジュールノードの 'children' も 'extra.hierarchy' に ▼▼▼
      local node = {
        id = meta.module_root,
        name = name,
        path = meta.module_root,
        type = "directory",
        extra = {
          uep_type = "module",
          hierarchy = file_tree,
          is_loaded = false
        },
      }
      -- ▲▲▲ 変更ここまで ▲▲▲
      
      if meta.location == "in_plugins" then
        local plugin_name = meta.module_root:match("[/\\]Plugins[/\\]([^/\\]+)")
        if plugin_name then
          local plugin_path = meta.module_root:match("(.+[/\\]Plugins[/\\][^/\\]+)")
          if not plugin_nodes[plugin_name] then
            -- ▼▼▼ 変更点 4: プラグインノードの初期化も同様に変更 ▼▼▼
            plugin_nodes[plugin_name] = {
              id = plugin_path,
              name = plugin_name,
              path = plugin_path,
              type = "directory",
              extra = {
                uep_type = "plugin",
                hierarchy = {},
                is_loaded = false
              },
            }
            -- ▲▲▲ 変更ここまで ▲▲▲
          end
          -- ▼▼▼ 変更点 5: 子ノードの追加先を 'children' から 'extra.hierarchy' に変更 ▼▼▼
          table.insert(plugin_nodes[plugin_name].extra.hierarchy, node)
        else
          table.insert(root_nodes.Plugins.extra.hierarchy, node)
        end
      elseif meta.location == "in_source" then
        local category_key = meta.category or "Game"
        if root_nodes[category_key] then
          table.insert(root_nodes[category_key].extra.hierarchy, node)
        end
        -- ▲▲▲ 変更ここまで ▲▲▲
      end
    end
  end
  for _, plugin_node in pairs(plugin_nodes) do table.insert(root_nodes.Plugins.extra.hierarchy, plugin_node) end
  
  local final_nodes = {}
  for _, category_name in ipairs({ "Game", "Engine", "Plugins" }) do
    local category_node = root_nodes[category_name]
    -- ▼▼▼ 変更点 6: 子ノードの存在チェックも 'extra.hierarchy' で行う ▼▼▼
    if category_node and category_node.extra.hierarchy and #category_node.extra.hierarchy > 0 then
      category_node.path = category_node.id
      table.insert(final_nodes, category_node)
    end
    -- ▲▲▲ 変更ここまで ▲▲▲
  end
  return final_nodes
end

-------------------------------------------------
-- プロバイダーの実装 (このセクションはほぼ変更なし)
-------------------------------------------------
local M = {}

-- (get_pending_tree_request 関数は変更なし)
function M.get_pending_tree_request(opts)
  local consumer_id = (opts and opts.consumer) or "unknown"
  uep_log.debug("Provider 'get_pending_tree_request' called by: %s", consumer_id)
  local handle = unl_context.use("UEP"):key("pending_request:" .. consumer_id)
  local payload = handle:get("payload")
  if payload then
    uep_log.info("Found and returning pending request for %s. The request will now be cleared.", consumer_id)
    handle:del("payload")
    return payload
  else
    uep_log.debug("No pending request found for %s.", consumer_id)
    return nil
  end
end

function M.build_tree_model(opts)
  opts = opts or {}
  local uep_project_cache = require("UEP.cache.project")
  local uep_files_cache = require("UEP.cache.files")
  
  local project_root = opts.project_root
  local engine_root = opts.engine_root
  if not project_root then return nil end

  local game_data = uep_project_cache.load(project_root)
  if not game_data then
    return nil
  end

  local engine_data = engine_root and uep_project_cache.load(engine_root)
  
  local all_modules_meta = {}
  if engine_data and engine_data.modules then
    for name, meta in pairs(engine_data.modules) do
      all_modules_meta[name] = meta
    end
    uep_log.debug("Provider: Manually merged %d modules from engine_data.", vim.tbl_count(engine_data.modules))
  end
  
  if game_data and game_data.modules then
    for name, meta in pairs(game_data.modules) do
      all_modules_meta[name] = meta
    end
    uep_log.debug("Provider: Manually merged/overwrote %d modules from game_data.", vim.tbl_count(game_data.modules))
  end

  if not next(all_modules_meta) then
      return nil
  end

  local target_module_names = {}

  if opts.target_module then
    target_module_names[opts.target_module] = true
    local start_module = all_modules_meta[opts.target_module]
    if start_module then
        local deps_key = opts.all_deps and "deep_dependencies" or "shallow_dependencies"
        if start_module[deps_key] then
            for _, dep_name in ipairs(start_module[deps_key]) do
                target_module_names[dep_name] = true
            end
        end
    end
  else
    for name, meta in pairs(all_modules_meta) do
      if meta.category == "Game" then
        target_module_names[name] = true
        local deps_key = opts.all_deps and "deep_dependencies" or "shallow_dependencies"
        if meta[deps_key] then
          for _, dep_name in ipairs(meta[deps_key]) do
            target_module_names[dep_name] = true
          end
        end
      end
    end
  end

  local filtered_modules_meta = {}
  for name, _ in pairs(target_module_names) do
    if all_modules_meta[name] then
      filtered_modules_meta[name] = all_modules_meta[name]
    end
  end

  local game_files = uep_files_cache.load(project_root) or { files_by_module = {} }
  local engine_files = engine_data and uep_files_cache.load(engine_data.root) or { files_by_module = {} }
  local all_files = vim.tbl_deep_extend("force", engine_files.files_by_module or {}, game_files.files_by_module or {})
  
  local hierarchy = build_hierarchy_nodes(filtered_modules_meta, all_files)
  
  if not next(hierarchy) then
    return {{ id = "_message_", name = "No modules to display with current filters.", type = "message" }}
  end
  
  local project_name = vim.fn.fnamemodify(game_data.uproject_path, ":t:r")
  -- ▼▼▼ 変更点 7: 最終的なツリーモデルも 'children' から 'extra.hierarchy' へ ▼▼▼
  local final_tree_model = {{
    id = project_root, name = project_name, path = project_root, type = "directory",
    extra = {
      uep_type = "project_root",
      hierarchy = hierarchy,
      is_loaded = false
    },
  }}
  -- ▲▲▲ 変更ここまで ▲▲▲
  
  return final_tree_model
end

-- (request 関数は変更なし)
function M.request(opts)
  if opts and opts.capability == "uep.get_pending_tree_request" then
    return M.get_pending_tree_request(opts)
  elseif opts and opts.capability == "uep.build_tree_model" then
    return M.build_tree_model(opts)
  else
    uep_log.warn("Unknown request to UEP tree provider: %s", vim.inspect(opts))
    return nil
  end
end

return M
