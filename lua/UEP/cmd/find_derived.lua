-- lua/UEP/cmd/find_derived.lua (完成版)

local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local unl_buf_open = require("UNL.buf.open")
local log = require("UEP.logger")

local M = {}

---
-- 指定された基底クラスの派生クラスを検索し、結果をPickerで表示するヘルパー関数
-- @param base_class_name string 基底クラスの名前
local function find_and_show_derived(base_class_name, opts)
  derived_core.get_derived_classes(base_class_name, opts, function(derived_classes)
    if not derived_classes or #derived_classes == 0 then
      local msg = "No derived classes found for: " .. base_class_name
      log.get().info(msg)
      return
    end

    -- Pickerで結果を表示
    unl_picker.pick({
      kind = "uep_derived_classes",
      title = "Derived Classes of: " .. base_class_name,
      conf = uep_config.get(),
      items = derived_classes, -- derived_coreが返すテーブルをそのまま渡す
      preview_enabled = true,
      on_submit = function(selected_class)
        if selected_class and selected_class.file_path then
          unl_buf_open.safe({
            file_path = selected_class.file_path,
            open_cmd = "edit",
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

  -- ケース1: bang (!) が指定された場合、強制的に基底クラス選択Pickerを表示
  if opts.has_bang then
    log.get().info("Bang detected! Forcing base class picker.")
    derived_core.get_all_classes({},function(all_classes)
      if not all_classes or #all_classes == 0 then
        return log.get().error("No classes found. Please run :UEP refresh.")
      end

      unl_picker.pick({
        kind = "uep_select_base_class",
        title = "Select Base Class to Find Derived",
        conf = uep_config.get(),
        items = all_classes,
        preview_enabled = true,
        on_submit = function(selected_class)
          if selected_class and selected_class.class_name then
            -- 選択されたクラスを元に、派生クラス検索を実行
            find_and_show_derived(selected_class.class_name, opts)
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
    -- クラス名が特定できたので、派生クラス検索を実行
    find_and_show_derived(target_class_name, opts)
  else
    -- クラス名が特定できず、bangもない場合はユーザーに通知
    local msg = "No class name specified. Use ':UEP find_derived!' to pick from a list."
    log.get().warn(msg)
  end
end

return M
