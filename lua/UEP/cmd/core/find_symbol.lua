-- lua/UEP/cmd/core/find_symbol.lua (DB一元化版)

local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")

local M = {}

----------------------------------------------------------------------
-- ヘルパー関数: シンボルリストをフィルタリングしてピッカー表示
----------------------------------------------------------------------
local function process_symbol_list(all_symbols_data, opts)
  local log = uep_log.get()
  local symbol_type = opts.symbol_type -- "class", "struct", or "enum"
  local scope = opts.scope or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"

  if not all_symbols_data then
    return log.error("Failed to get symbol list (scope=%s, deps=%s). (Run :UEP refresh)", scope, deps_flag)
  end

  -- Rust側ですでに symbol_type によるフィルタリングは完了しているため、
  -- ここでの再フィルタリングをスキップして直接渡す
  local filtered_list = all_symbols_data

  if #filtered_list == 0 then
    return log.warn("No %ss found in the cache for scope=%s, deps=%s.", symbol_type, scope, deps_flag)
  end

  local scope_display = scope:gsub("^%l", string.upper)
  local deps_display = ""
  if deps_flag == "--shallow-deps" then deps_display = " (Shallow)"
  elseif deps_flag == "--no-deps" then deps_display = " (No Deps)"
  else deps_display = " (Deep)" end

  local picker_title = ("Select %s [%s%s]"):format(
                         symbol_type:gsub("^%l", string.upper),
                         scope_display,
                         deps_display)

  unl_picker.pick({
    kind = "uep_select_" .. symbol_type,
    title = picker_title,
    items = filtered_list,
    conf = uep_config.get(),
    preview_enabled = true,
    on_submit = function(selected_info)
      if selected_info and selected_info.file_path and selected_info.class_name then
        core_utils.open_file_and_jump(selected_info.file_path, selected_info.class_name)
      end
    end,
  })
end

----------------------------------------------------------------------
-- 公開API関数 (find_and_jump)
----------------------------------------------------------------------
function M.find_and_jump(opts)
  opts = opts or {}
  local log = uep_log.get()
  opts.scope = opts.scope or "runtime"
  opts.deps_flag = opts.deps_flag or "--deep-deps"

  log.info("Fetching symbols from DB (scope=%s, deps=%s)...", opts.scope, opts.deps_flag)

  -- キャッシュロジックを廃止し、常に derived_core.get_all_classes (DB経由) を呼び出す
  derived_core.get_all_classes(opts, function(all_symbols)
    if all_symbols then
      process_symbol_list(all_symbols, opts)
    else
      log.error("Failed to fetch symbols from DB.")
      vim.notify("UEP: Failed to fetch symbols. Check logs.", vim.log.levels.ERROR)
    end
  end)
end

return M
