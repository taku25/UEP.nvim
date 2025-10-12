-- lua/UEP/cmd/find_parents.lua

local derived_core = require("UEP.cmd.core.derived")
local parents_core = require("UEP.cmd.core.parents")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")

local M = {}

-- 継承チェーンをPickerで表示するヘルパー関数
local function show_parents_picker(chain, child_class_name)
  if #chain == 0 then
    return uep_log.get().info("No parent classes found for '%s'.", child_class_name)
  end

  local picker_items = {}
  for i, class_info in ipairs(chain) do
    table.insert(picker_items, {
      display = string.format("%d: %s", i, class_info.class_name), -- 階層が分かりやすいように番号を振る
      value = class_info.file_path,
      filename = class_info.file_path,
    })
  end

  unl_picker.pick({
    kind = "uep_parent_classes",
    title = ("Inheritance Chain of '%s'"):format(child_class_name),
    items = picker_items,
    conf = uep_config.get(),
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

  -- find_derived と同じく、まずプロジェクトの全クラス情報を取得
  derived_core.get_all_classes(function(all_classes)
    if not all_classes then
      return log.error("Could not retrieve class information. Please run :UEP refresh.")
    end

    if target_class_name then
      -- 引数が指定されている場合：直接、継承チェーンを検索して表示
      local chain = parents_core.get_inheritance_chain(target_class_name, all_classes)
      show_parents_picker(chain, target_class_name)
    else
      -- 引数がない場合：まず起点となるクラスを選択させるPickerを表示
      local picker_items = {}
      for _, class_info in ipairs(all_classes) do
        table.insert(picker_items, {
          display = class_info.class_name,
          value = class_info.class_name,
          filename = class_info.file_path,
        })
      end

      unl_picker.pick({
        kind = "uep_select_child_class",
        title = "Select a Class to find its parents",
        items = picker_items,
        conf = uep_config.get(),
        preview_enabled = true,
        on_submit = function(selected_child_class)
          if not selected_child_class then return end
          local chain = parents_core.get_inheritance_chain(selected_child_class, all_classes)
          show_parents_picker(chain, selected_child_class)
        end,
      })
    end
  end)
end

return M
