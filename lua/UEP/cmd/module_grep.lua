-- lua/UEP/cmd/module_grep.lua (リファクタリング版)

local grep_core = require("UEP.cmd.core.grep")
local files_core = require("UEP.cmd.core.files") -- ★ files_core を使う
local uep_log = require("UEP.logger")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")

local M = {}

---
-- 指定されたモジュール情報でLive Grepを開始する内部関数
-- @param target_module_info table モジュールキャッシュのメタデータ
local function start_grep_for_module(target_module_info)
  if not (target_module_info and target_module_info.module_root) then
    return uep_log.get().error("Module info is invalid or missing 'module_root'.")
  end

  grep_core.start_live_grep({
    search_paths = { target_module_info.module_root },
    title = string.format("Live Grep (in %s)", target_module_info.name),
    initial_query = "",
  })
end

---
-- コマンドビルダーから呼び出される実行関数
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 新しいキャッシュシステムからプロジェクトの全情報を非同期で取得
  files_core.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("Failed to get project info from cache: %s", tostring(maps))
      return
    end
    
    local all_modules_map = maps.all_modules_map
    
    if opts.module_name then
      -- 引数でモジュール名が指定されている場合
      local target_module_info = all_modules_map[opts.module_name]
      if target_module_info then
        start_grep_for_module(target_module_info)
      else
        log.error("Module '%s' not found in cache.", opts.module_name)
      end
    else
      -- 引数がない場合、ピッカーで選択させる
      local picker_items = {}
      for name, meta in pairs(all_modules_map) do
        table.insert(picker_items, { label = string.format("%s (%s)", name, meta.category), value = name })
      end
      table.sort(picker_items, function(a, b) return a.value < b.value end)
      
      unl_picker.pick({
        kind = "uep_select_module_for_grep",
        title = "Select a Module to Search",
        items = picker_items,
        conf = uep_config.get(),
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
