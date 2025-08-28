-- lua/UEP/cmd/module_files.lua

local project_cache = require("UEP.cache.project")
local files_core    = require("UEP.cmd.files_core")
local unl_picker    = require("UNL.backend.picker")
local uep_log      = require("UEP.logger")
local refresh_cmd  = require("UEP.cmd.refresh")
local uep_config   = require("UEP.config")

local M = {}

local function show_file_picker(items, project_root)
  if not items or #items == 0 then
    uep_log.get().info("No matching files found for this module.")
    return
  end
 -- 1. ファイルパスのリストを、ピッカー用のテーブル形式に変換する
  local picker_items = {}
  local root_prefix = project_root .. "/"
  for _, file_path in ipairs(items) do
    table.insert(picker_items, {
      -- 表示ラベル: プロジェクトルートからの相対パス
      label = file_path:gsub(root_prefix, ""),
      -- 値: プレビューやファイルを開くためにフルパスを保持
      value = { filename = file_path, text = file_path:gsub(root_prefix, "") }
    })
  end

  -- 2. 見た目のためにアルファベット順でソートする
  table.sort(picker_items, function(a, b) return a.label < b.label end)

  -- 3. UNLのピッカーを呼び出す
  unl_picker.pick({
    kind = "module_file_location",
    title = "  Module Files",
    items = picker_items,
    preview_enabled = false,
    conf = uep_config.get(),
    logger_name = uep_log.name,
    on_submit = function(selection)
      -- 4. ユーザーがファイルを選択したら、そのファイルを開く
      if selection and selection.filename then
        pcall(vim.cmd.edit, selection.filename)
      end
    end
  })
end

function M.execute(opts)
  -- 1. データの読み込み (共通)
  local game_data = project_cache.load(vim.loop.cwd())
  if not game_data then return end
  local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil
  local all_modules = {}
  if game_data and game_data.modules then
    for name, meta in pairs(game_data.modules) do all_modules[name] = meta end
  end
  if engine_data and engine_data.modules then
    for name, meta in pairs(engine_data.modules) do
      if not all_modules[name] then all_modules[name] = meta end
    end
  end

  -- 2. 共通のヘルパー関数を定義
  local function search_and_display(module_name)
    if not all_modules[module_name] then
      uep_log.get().error(("Module '%s' not found."):format(module_name))
      return
    end
    local files = files_core.get_files_from_cache({
      required_modules = { module_name },
      project_root = game_data.root,
      engine_root = game_data.link_engine_cache_root,
    })
    if not files then return end
    show_file_picker(files, game_data.root)
  end
  
  local function refresh_and_display(module_name)
    uep_log.get().info(("Updating file cache for module '%s'..."):format(module_name))
    refresh_cmd.update_file_cache_for_single_module(module_name, function(ok)
      if ok then
        search_and_display(module_name)
      else
        uep_log.get().error("Failed to update file cache.")
      end
    end)
  end

  -- 3. !の有無で処理を完全に分岐
  if opts.has_bang then
    -- ===============================
    -- ★ キャッシュ更新モード (!)
    -- ===============================
    if opts.module_name then
      refresh_and_display(opts.module_name)
    else
      local picker_items = {}
      for name, meta in pairs(all_modules) do
        table.insert(picker_items, { label = string.format("%s (%s)", name, meta.category), value = name })
      end
      table.sort(picker_items, function(a, b) return a.value < b.value end)
      
      unl_picker.pick({
        kind = "module_select_for_refresh", 
        title = "Select a Module to REFRESH files",
        items = picker_items,
        format = function(item) return item.label end,
        conf = uep_config.get(),
        on_submit = function(selected_module_name)
          if selected_module_name then
            refresh_and_display(selected_module_name)
          end
        end,
        config_name = uep_config.name,
        logger_name = uep_log.name,
      })
    end
  else
    -- ===============================
    -- ★ 通常モード
    -- ===============================
    if opts.module_name then
      search_and_display(opts.module_name)
    else
      local picker_items = {}
      for name, meta in pairs(all_modules) do
        table.insert(picker_items, { label = string.format("%s (%s)", name, meta.category), value = name })
      end
      table.sort(picker_items, function(a, b) return a.value < b.value end)
      
      unl_picker.pick({
        kind = "module_select", 
        title = "Select a Module",
        items = picker_items,
        conf = uep_config.get(),
        format = function(item) return item.label end,
        on_submit = function(selected_module_name)
          if selected_module_name then
            search_and_display(selected_module_name)
          end
        end,
        logger_name = uep_log.name,
      })
    end
  end
end

return M
