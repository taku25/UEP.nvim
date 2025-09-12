-- lua/UEP/provider/tree.lua (モジュール中心設計・最終完成版)

local unl_context = require("UNL.context")
local uep_log = require("UEP.logger").get()
local uep_project_cache = require("UEP.cache.project")
local uep_files_cache = require("UEP.cache.files")
local fs = require("vim.fs")

local M = {}

-------------------------------------------------
-- ヘルパー関数
-------------------------------------------------

local function directory_first_sorter(a, b)
  if a.type == "directory" and b.type ~= "directory" then return true
  elseif a.type ~= "directory" and b.type == "directory" then return false
  else return a.name < b.name end
end

local function build_fs_hierarchy(root_path, files, dirs)
    local dir_set = {}
    for _, dir_path in ipairs(dirs or {}) do
        -- ★★★ 修正箇所: 格納する前に、末尾のスラッシュを確実に除去 ★★★
        dir_set[dir_path:gsub("[/\\]$", "")] = true
    end
    local all_paths = {}
    if files then vim.list_extend(all_paths, files) end
    if dirs then vim.list_extend(all_paths, dirs) end
    if #all_paths == 0 then return {} end
    local trie = {}
    for _, raw_full_path in ipairs(all_paths) do
        local full_path = raw_full_path:gsub("[/\\]$", "")

        if full_path:find(root_path, 1, true) and full_path ~= root_path then
            local current_level = trie

            -- ★★★ これが、曖昧さを完全に排除した、最後の聖剣です ★★★
            -- 1. まず、パスの先頭からroot_path部分を安全に除去する
            local relative_path = full_path:gsub(vim.pesc(root_path), "", 1)
            -- 2. 次に、先頭に残った可能性のあるパス区切り文字を除去する
            relative_path = relative_path:gsub("^[/\\]", "")
            
            local parts = vim.split(relative_path, "[/\\]")
            for _, part in ipairs(parts) do
                if part ~= "" then
                    if not current_level[part] then current_level[part] = {} end
                    current_level = current_level[part]
                end
            end
        end
    end
    local function trie_to_nodes(sub_trie, current_path)
        local nodes = {}
        for name, content in pairs(sub_trie) do
            local new_path = fs.joinpath(current_path, name)
            local node_type = "file"
            local hierarchy = nil
            if dir_set[new_path] or next(content) then
                node_type = "directory"
                hierarchy = trie_to_nodes(content, new_path)
            end
            table.insert(nodes, {
                id = new_path, name = name, path = new_path, type = node_type,
                extra = { is_loaded = false, hierarchy = hierarchy },
            })
        end
        table.sort(nodes, directory_first_sorter)
        return nodes
    end
    return trie_to_nodes(trie, root_path)
end

local function build_logical_hierarchy(modules_meta, all_modules_data)
  local root_categories = {
    Game = { id = "category_Game", name = "Game", type = "directory", extra = { uep_type = "category", hierarchy = {}, is_loaded = false } },
    Plugins = { id = "category_Plugins", name = "Plugins", type = "directory", extra = { uep_type = "category", hierarchy = {}, is_loaded = false } },
    Engine = { id = "category_Engine", name = "Engine", type = "directory", extra = { uep_type = "category", hierarchy = {}, is_loaded = false } },
  }
  local plugin_nodes = {}

  for name, meta in pairs(modules_meta) do
    if meta.module_root and all_modules_data[name] then
      local module_data = all_modules_data[name]
      local file_tree = build_fs_hierarchy(meta.module_root, module_data.files, module_data.directories)
      local node = {
        id = meta.module_root, name = name, path = meta.module_root, type = "directory",
        extra = { uep_type = "module", hierarchy = file_tree, is_loaded = false },
      }
      if meta.location == "in_plugins" then
        local plugin_name = meta.module_root:match("[/\\]Plugins[/\\]([^/\\]+)")
        if plugin_name then
          local plugin_path = meta.module_root:match("(.+[/\\]Plugins[/\\][^/\\]+)")
          if not plugin_nodes[plugin_name] then
            plugin_nodes[plugin_name] = {
              id = plugin_path, name = plugin_name, path = plugin_path, type = "directory",
              extra = { uep_type = "plugin", hierarchy = {}, is_loaded = false },
            }
          end
          table.insert(plugin_nodes[plugin_name].extra.hierarchy, node)
        else
          table.insert(root_categories.Plugins.extra.hierarchy, node)
        end
      elseif meta.location == "in_source" then
        local category_key = meta.category or "Game"
        if root_categories[category_key] then
          table.insert(root_categories[category_key].extra.hierarchy, node)
        end
      end
    end
  end

  for _, plugin_node in pairs(plugin_nodes) do
    table.sort(plugin_node.extra.hierarchy, directory_first_sorter)
    table.insert(root_categories.Plugins.extra.hierarchy, plugin_node)
  end
  local final_nodes = {}
  for _, category_name in ipairs({ "Game", "Engine", "Plugins" }) do
    local category_node = root_categories[category_name]
    if #category_node.extra.hierarchy > 0 then
      table.sort(category_node.extra.hierarchy, directory_first_sorter)
      table.insert(final_nodes, category_node)
    end
  end
  return final_nodes
end

-------------------------------------------------
-- プロバイダー公開関数
-------------------------------------------------

function M.get_pending_tree_request(opts)
  local consumer_id = (opts and opts.consumer) or "unknown"
  local handle = unl_context.use("UEP"):key("pending_request:" .. consumer_id)
  local payload = handle:get("payload")
  if payload then handle:del("payload"); return payload end
  return nil
end

function M.build_tree_model(opts)
  opts = opts or {}
  local project_root = opts.project_root
  local engine_root = opts.engine_root
  if not project_root then return nil end
  local game_data = uep_project_cache.load(project_root)
  if not game_data then return nil end
  local engine_data = engine_root and uep_project_cache.load(engine_root)
  local all_modules_meta = vim.tbl_deep_extend("force", {}, engine_data and engine_data.modules or {}, game_data.modules or {})
  if not next(all_modules_meta) then return nil end
  local target_module_names = {}
  if opts.target_module then
    target_module_names[opts.target_module] = true
    local start_module = all_modules_meta[opts.target_module]
    if start_module and start_module[opts.all_deps and "deep_dependencies" or "shallow_dependencies"] then
      for _, dep_name in ipairs(start_module[opts.all_deps and "deep_dependencies" or "shallow_dependencies"]) do target_module_names[dep_name] = true end
    end
  else
    for name, meta in pairs(all_modules_meta) do
      if meta.category == "Game" then
        target_module_names[name] = true
        if meta[opts.all_deps and "deep_dependencies" or "shallow_dependencies"] then
          for _, dep_name in ipairs(meta[opts.all_deps and "deep_dependencies" or "shallow_dependencies"]) do target_module_names[dep_name] = true end
        end
      end
    end
  end
  local filtered_modules_meta = {}
  for name, _ in pairs(target_module_names) do
    if all_modules_meta[name] then filtered_modules_meta[name] = all_modules_meta[name] end
  end
  local game_cache = uep_files_cache.load(project_root) or {}
  local engine_cache = engine_root and uep_files_cache.load(engine_root) or {}
  local all_modules_data = vim.tbl_deep_extend("force", {}, engine_cache.modules_data or {}, game_cache.modules_data or {})
  local hierarchy = build_logical_hierarchy(filtered_modules_meta, all_modules_data)
  if not next(hierarchy) then
    return {{ id = "_message_", name = "No modules to display with current filters.", type = "message" }}
  end
  local project_name = vim.fn.fnamemodify(game_data.uproject_path, ":t:r")
  return {{
    id = project_root, name = project_name, path = project_root, type = "directory",
    extra = { uep_type = "project_root", hierarchy = hierarchy, is_loaded = false },
  }}
end

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
