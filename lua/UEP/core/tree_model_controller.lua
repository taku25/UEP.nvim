-- UEP/core/tree_model_controller.lua
-- キャッシュを読み込み、引数に基づいてneo-tree用のツリーモデルを構築する責務を担う。
-- このモジュールは、モデルの「コントローラー」として機能します。

local files_cache = require("UEP.cache.files")
local project_cache = require("UEP.cache.project")
local uep_log = require("UEP.logger")

local M = {}

function M.build(project_root, args)
  local log = uep_log.get()
  args = args or {}

  -- --- ステップ1: 常にプロジェクト全体のモデルを構築する準備を行う ---
  log.debug("Controller: Starting build process...")

  -- 1a. プロジェクトの基本情報をロード
  local game_project_data = project_cache.load(project_root)
  if not game_project_data then
    log.error("Failed to load project cache data. Aborting build.")
    return false, nil
  end
  local project_name = vim.fn.fnamemodify(game_project_data.uproject_path, ":t:r") or "Unknown Project"

  -- 1b. 表示の基点となる「プロジェクトルートノード」を作成
  local root_node = {
    name = project_name, type = "directory", path = project_root, id = project_root,
    extra = { uep_type = "project_root" },
    children = {}, -- この children に何を入れるかを後で決める
  }

  -- 1c. 表示に必要な「階層データ」をキャッシュからロード・マージする
  local hierarchy_nodes = {}
  local game_files_data = files_cache.load(project_root)
  if game_files_data and game_files_data.hierarchy_nodes then
    for _, node in ipairs(game_files_data.hierarchy_nodes) do table.insert(hierarchy_nodes, node) end
  end
  if game_project_data.link_engine_cache_root then
    local engine_files_data = files_cache.load(game_project_data.link_engine_cache_root)
    if engine_files_data and engine_files_data.hierarchy_nodes then
      for _, node in ipairs(engine_files_data.hierarchy_nodes) do table.insert(hierarchy_nodes, node) end
    end
  end

  -- --- ステップ2: 引数に応じて、root_node.children の中身を決定する ---
  if args.module_name then
    -- ===============================
    -- ★ 単一モジュールビューの場合 ★
    -- ===============================
    log.info("Request is for a single module view: %s", args.module_name)
    
    if #hierarchy_nodes == 0 then
      log.error("Hierarchy data is empty, cannot find module '%s'.", args.module_name)
      return true, { root_node } -- ルートだけ表示
    end

    local function find_module_node_recursive(nodes_to_search)
      for _, node in ipairs(nodes_to_search) do
        if node.extra and node.extra.uep_type == "module" and node.name == args.module_name then return node end
        if node.children and #node.children > 0 then
          local found_in_child = find_module_node_recursive(node.children)
          if found_in_child then return found_in_child end
        end
      end
      return nil
    end
    
    local target_module_node = find_module_node_recursive(hierarchy_nodes)
    
    if target_module_node then
      log.debug("Single module node successfully isolated.")
      -- ルートノードの children を、見つけたモジュールノードだけに差し替える
      root_node.children = { target_module_node }
    else
      log.error("Could not isolate module node '%s'. Displaying root only.", args.module_name)
      root_node.children = {} -- 見つからなかった場合は空にする
    end
  else
    -- ===========================
    -- ★ プロジェクト全体ビューの場合 ★
    -- ===========================
    log.info("Request is for the full project view.")
    if #hierarchy_nodes == 0 then
      log.warn("No hierarchy data found in cache to build the tree.")
    end
    -- ルートノードの children に、全ての階層データを入れる
    root_node.children = hierarchy_nodes
  end

  -- --- ステップ3: 常に同じ構造のデータを返す ---
  log.debug("Build process complete. Returning final model.")
  return true, { root_node }
end

return M
