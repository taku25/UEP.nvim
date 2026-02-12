-- lua/UEP/cmd/core/find_symbol.lua (DB一元化版)

local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")

local M = {}

----------------------------------------------------------------------
-- 公開API関数 (find_and_jump)
----------------------------------------------------------------------
function M.find_and_jump(opts)
  opts = opts or {}
  local log = uep_log.get()
  opts.scope = opts.scope or "runtime"
  opts.deps_flag = opts.deps_flag or "--deep-deps"
  local symbol_type = opts.symbol_type or "class"

  local scope_display = opts.scope:gsub("^%l", string.upper)
  local deps_display = ""
  if opts.deps_flag == "--shallow-deps" then deps_display = " (Shallow)"
  elseif opts.deps_flag == "--no-deps" then deps_display = " (No Deps)"
  else deps_display = " (Deep)" end

  local picker_title = ("Select %s [%s%s]"):format(
                         symbol_type:gsub("^%l", string.upper),
                         scope_display,
                         deps_display)

  log.info("Fetching symbols from DB (scope=%s, deps=%s)...", opts.scope, opts.deps_flag)

  unl_picker.open({
    kind = "uep_select_" .. symbol_type,
    title = picker_title,
    conf = uep_config.get(),
    preview_enabled = true,
    devicons_enabled = true,
    start = function(push)
      derived_core.get_all_classes_async(opts, function(chunk)
        push(chunk)
      end, function(ok, total)
        if ok then
          log.debug("Symbol fetch complete. Total: %s", tostring(total))
        else
          log.error("Symbol fetch failed: %s", tostring(total))
        end
      end)
    end,
    on_submit = function(selected_info)
      if selected_info and selected_info.file_path and selected_info.class_name then
        core_utils.open_file_and_jump(selected_info.file_path, selected_info.class_name)
      end
    end,
  })
end

return M


