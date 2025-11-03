-- lua/UEP/cmd/module_files.lua (新コアロジック対応版)

local files_core = require("UEP.cmd.core.files") -- ★ 新しい core/files を使う
local unl_picker = require("UNL.backend.picker")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")
-- local projects_cache = require("UEP.cache.projects") -- utils経由で取得するので不要
-- local unl_finder = require("UNL.finder") -- utils経由で取得するので不要
local uep_utils = require("UEP.cmd.core.utils") -- ★ utils を require

local M = {}

-- ▼▼▼ show_file_picker を修正 ▼▼▼
-- @param items table: ファイルパスのリスト
-- @param module_meta table: モジュールのメタデータ (module_root を含む)
local function show_file_picker(items, module_meta)
  if not items or #items == 0 then
    uep_log.get().info("No matching files found for module '%s'.", module_meta.name)
    return
  end
  local picker_items = {}
  local base_path = module_meta.module_root -- ★ モジュールルートを基準パスとする

  for _, file_path in ipairs(items) do
    table.insert(picker_items, {
      -- ★ utils.create_relative_path を使用
      label = uep_utils.create_relative_path(file_path, base_path),
      -- value は edit コマンドで使えるようにフルパスを text として保持
      value = { filename = file_path, text = file_path }
    })
  end

  table.sort(picker_items, function(a, b) return a.label < b.label end)

  unl_picker.pick({
    kind = "uep_module_file_picker", -- kind 名を変更
    title = (" Files in Module: %s"):format(module_meta.name), -- タイトルにモジュール名
    items = picker_items,
    preview_enabled = true,
    devicons_enabled  = true,
    conf = uep_config.get(),
    logger_name = uep_log.name,
    on_submit = function(selection)
      -- selection は { filename = ..., text = ... } テーブル
      if selection and selection.filename then
        pcall(vim.cmd.edit, vim.fn.fnameescape(selection.filename))
      end
    end
  })
end
-- ▲▲▲ show_file_picker 修正ここまで ▲▲▲

-- ▼▼▼ search_and_display を修正 ▼▼▼
local function search_and_display(module_name)
  local log = uep_log.get()
  log.info("Searching files for module: %s", module_name)

  -- ★ 新しい files_core.get_files_for_module を呼び出す
  files_core.get_files_for_module(module_name, function(ok, result)
    if not ok then
      log.error("Failed to get module files for '%s': %s", module_name, tostring(result))
      vim.notify(string.format("Error getting files for %s.", module_name), vim.log.levels.ERROR)
      return
    end

    -- result は { files = {...}, module_meta = {...} }
    show_file_picker(result.files, result.module_meta)
  end)
end
-- ▲▲▲ search_and_display 修正ここまで ▲▲▲

-- ▼▼▼ execute 関数を修正 (モジュールピッカー部分) ▼▼▼
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- (refresh_and_display 関数は変更なし)
  local function refresh_and_display(module_name)
    local refresh_cmd = "UEP refresh!"
    log.info("Bang detected. Running '%s' first...", refresh_cmd)
    local sub_id
    sub_id = unl_events.subscribe(unl_types.ON_AFTER_REFRESH_COMPLETED, function()
      unl_events.unsubscribe(sub_id)
      log.info("Refresh completed. Now searching module files.")
      vim.schedule(function() search_and_display(module_name) end)
    end)
    vim.api.nvim_command(refresh_cmd)
  end

  local main_logic_handler = opts.has_bang and refresh_and_display or search_and_display

  if opts.module_name then
    main_logic_handler(opts.module_name)
  else
    -- モジュール名がない場合はピッカーを表示
    log.info("No module name specified, showing picker...")
    -- ★ utils.get_project_maps を使ってモジュールリストを取得
    uep_utils.get_project_maps(vim.loop.cwd(), function(map_ok, maps)
        if not map_ok then
            log.error("Failed to get module list for picker: %s", tostring(maps))
            return vim.notify("Error getting module list.", vim.log.levels.ERROR)
        end

        local all_modules_picker = {}
        -- maps.all_modules_map からピッカーアイテムを作成
        for mod_name, mod_meta in pairs(maps.all_modules_map or {}) do
             -- owner_name を使って所属を表示 (Game/Engine/Plugin)
             local owner_display = "Unknown"
             if maps.all_components_map and maps.all_components_map[mod_meta.owner_name] then
                 owner_display = maps.all_components_map[mod_meta.owner_name].type -- "Game", "Engine", "Plugin"
             end
             table.insert(all_modules_picker, {
                 label = string.format("%s (%s - %s)", mod_name, owner_display, mod_meta.type or "N/A"), -- タイプも表示
                 value = mod_name
             })
        end

        if #all_modules_picker == 0 then return log.error("No modules found for picker.") end
        table.sort(all_modules_picker, function(a, b) return a.label < b.label end)

        unl_picker.pick({
          kind = "uep_select_module", -- kind 名を変更
          title = "Select a Module",
          items = all_modules_picker,
          conf = uep_config.get(),
          preview_enabled = false, devicons_enabled = false, -- プレビュー/アイコン不要
          on_submit = function(selected_module_name)
            if selected_module_name then
              main_logic_handler(selected_module_name)
            end
          end,
          logger_name = uep_log.name,
        })
    end)
  end
end
-- ▲▲▲ execute 関数修正ここまで ▲▲▲

return M
