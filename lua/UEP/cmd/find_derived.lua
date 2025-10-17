-- lua/UEP/cmd/find_derived.lua

local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")

local M = {}

-- 派生クラスのリストをPickerで表示するヘルパー関数
local function show_derived_picker(derived_list, base_class_name)
  if #derived_list == 0 then
    return uep_log.get().info("No derived classes found for '%s'.", base_class_name)
  end

  local picker_items = {}
  for _, class_info in ipairs(derived_list) do
    table.insert(picker_items, {
      display = class_info.class_name,   -- 表示用テキスト
      value = class_info.file_path,      -- 決定時に返される値
      filename = class_info.file_path,   -- プレビュー用のファイルパス
    })
  end

  unl_picker.pick({
    kind = "uep_derived_classes",
    title = ("Derived Classes of '%s'"):format(base_class_name),
    items = picker_items,
    conf = uep_config.get(),
    -- プレビューを有効にする
    preview_enabled = true,
    on_submit = function(selected_file)
      if selected_file then
        vim.cmd.edit(vim.fn.fnameescape(selected_file))
      end
    end,
  })
end

-- メインの実行関数
function M.execute(opts)
  local log = uep_log.get()
  opts = opts or {}
  local target_class_name = opts.class_name

  -- まずプロジェクトの全クラス情報を非同期で取得
  derived_core.get_all_classes(function(all_classes)
    if not all_classes then
      return log.error("Could not retrieve class information. Please run :UEP refresh.")
    end

    if target_class_name then
      -- 引数が指定されている場合：直接、派生クラスを検索して表示
      local derived_list = derived_core.find_derived_in_list(target_class_name, all_classes)
      show_derived_picker(derived_list, target_class_name)
    else
      -- 引数がない場合：まず基底クラスを選択させるPickerを表示
      local picker_items = {}
      -- ▼▼▼ 修正点 2/2: ここにプレビュー用の `filename` を追加 ▼▼▼
      for _, class_info in ipairs(all_classes) do
        table.insert(picker_items, {
          display = class_info.class_name,   -- 表示用テキスト
          value = class_info.class_name,     -- 決定時に返される値
          filename = class_info.file_path,   -- ★プレビュー用のファイルパスを追加★
        })
      end

      unl_picker.pick({
        kind = "uep_select_base_class",
        title = "Select a Base Class to find derived classes",
        items = picker_items,
        conf = uep_config.get(),
        -- プレビューを有効にする
        preview_enabled = true,
        on_submit = function(selected_base_class)
          if not selected_base_class then return end
          local derived_list = derived_core.find_derived_in_list(selected_base_class, all_classes)
          show_derived_picker(derived_list, selected_base_class)
        end,
      })
    end
  end)
end

return M
