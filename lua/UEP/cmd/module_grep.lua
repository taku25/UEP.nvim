-- lua/UEP/cmd/module_grep.lua
local grep_core = require("UEP.cmd.core.grep")
local uep_core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")

local M = {}

---
-- 特定のモジュールでLive Grepを開始する内部関数
-- @param target_module_info table モジュールのメタデータ
local function start_grep_for_module(target_module_info)
  if not (target_module_info and target_module_info.module_root) then
    return uep_log.get().error("Module info is invalid or missing 'module_root'.")
  end

  -- ★ 1. `grep_core`を呼び出す。責務はこれだけ！
  -- これまで`grep`コマンドで培ってきた全ての機能が、この一行で有効になる。
  grep_core.start_live_grep({
    -- 検索範囲を、このモジュールのルートディレクトリ「だけ」に限定する
    search_paths = { target_module_info.module_root },
    -- ピッカーのタイトルを、モジュール名に合わせて分かりやすくする
    title = string.format("Live Grep (%s)", target_module_info.name),
  })
end

---
-- コマンドビルダーから呼び出される実行関数
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  uep_core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("Failed to get project info from cache: %s", tostring(maps))
      return
    end
    
    local all_modules_map = maps.all_modules_map
    
    if opts.module_name then
      local target_module_info = all_modules_map[opts.module_name]
      if target_module_info then
        start_grep_for_module(target_module_info)
      else
        log.error("Module '%s' not found in cache.", opts.module_name)
      end
    else
      local picker_items = {}
      for name, meta in pairs(all_modules_map) do
        table.insert(picker_items, { 
          label = string.format("%s (%s)", name, meta.category), 
          value = name 
        })
      end
      table.sort(picker_items, function(a, b) return a.label < b.label end)
      
      unl_picker.pick({
        kind = "uep_select_module_for_grep",
        title = "Select a Module to Grep",
        items = picker_items,
        conf = uep_config.get(),
        
        -- ★★★ ここが最後の修正箇所です ★★★
        -- モジュールリストはファイルではないため、deviconを無効にします
        devicons_enabled = false,
        -- 同様に、プレビューも不要なので無効にします
        preview_enabled = false,

        on_submit = function(selected_module_name)
          if selected_module_name then
            start_grep_for_module(all_modules_map[selected_module_name])
          end
        end,
      })
    end
  end)
end

return M
