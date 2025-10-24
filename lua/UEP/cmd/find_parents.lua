-- lua/UEP/cmd/find_parents.lua (完成版)

local derived_core = require("UEP.cmd.core.derived")
local parents_core = require("UEP.cmd.core.parents")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local unl_buf_open = require("UNL.buf.open")
local log = require("UEP.logger")

local M = {}

---
-- 指定されたクラスの継承チェーンを検索し、結果をPickerで表示するヘルパー関数
-- @param child_class_name string 起点となるクラスの名前
local function find_and_show_parents(child_class_name)
  -- 継承チェーンの検索には全クラスの情報が必要
  derived_core.get_all_classes({},function(all_classes)
    if not all_classes then
      return log.get().error("Could not retrieve class information for parent search.")
    end

    local chain = parents_core.get_inheritance_chain(child_class_name, all_classes)

    if not chain or #chain == 0 then
      local msg = "No parent classes found for: " .. child_class_name
      log.get().info(msg)
      vim.notify(msg)
      return
    end

    local picker_items = {}
    for i, class_info in ipairs(chain) do
      table.insert(picker_items, {
        display = string.format("%d: %s", i, class_info.class_name), -- 階層番号を表示
        value = class_info, -- on_submitでテーブル全体を受け取る
        filename = class_info.file_path,
      })
    end

    unl_picker.pick({
      kind = "uep_parent_classes",
      title = "Inheritance Chain of: " .. child_class_name,
      conf = uep_config.get(),
      items = picker_items,
      preview_enabled = true,
      on_submit = function(selected_class)
        if selected_class and selected_class.file_path then
          unl_buf_open.safe({
            file_path = selected_class.file_path,
            plugin_name = "UEP",
          })
        end
      end,
    })
  end)
end

---
-- メインの実行関数 (フロー制御を担当)
function M.execute(opts)
  opts = opts or {}

  -- ケース1: bang (!) が指定された場合、強制的に起点クラス選択Pickerを表示
  if opts.has_bang then
    log.get().info("Bang detected! Forcing child class picker.")
    derived_core.get_all_classes({},function(all_classes)
      if not all_classes or #all_classes == 0 then
        return log.get().error("No classes found. Please run :UEP refresh.")
      end

      unl_picker.pick({
        kind = "uep_select_child_class",
        title = "Select a Class to Find its Parents",
        conf = uep_config.get(),
        items = all_classes,
        preview_enabled = true,
        on_submit = function(selected_class)
          if selected_class and selected_class.class_name then
            -- 選択されたクラスを元に、継承チェーン検索を実行
            find_and_show_parents(selected_class.class_name)
          end
        end,
      })
    end)
    -- bang処理はここで終了
    return
  end

  -- ケース2: bangがない場合、引数またはカーソル下の単語を試す
  local target_class_name = opts.class_name or vim.fn.expand('<cword>')

  if target_class_name and target_class_name ~= "" then
    -- クラス名が特定できたので、継承チェーン検索を実行
    find_and_show_parents(target_class_name)
  else
    -- クラス名が特定できず、bangもない場合はユーザーに通知
    local msg = "No class name specified. Use ':UEP find_parents!' to pick from a list."
    log.get().warn(msg)
    vim.notify(msg, vim.log.levels.WARN)
  end
end

return M
