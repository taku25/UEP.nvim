-- lua/UEP/cmd/files.lua (最終完成版)

local dynamic_picker = require("UNL.backend.dynamic_picker")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")
local unl_cache_core = require("UNL.cache.core")

local M = {}

local plugin_roots_cache = {}
local function get_plugin_root(plugin_name)
  if plugin_roots_cache[plugin_name] then return plugin_roots_cache[plugin_name] end
  for _, rtp in ipairs(vim.opt.runtimepath:get()) do
    local marker_path = vim.fs.joinpath(rtp, "lua", plugin_name, "init.lua")
    if vim.fn.filereadable(marker_path) == 1 then
      plugin_roots_cache[plugin_name] = rtp
      return rtp
    end
  end
  uep_log.get().error("Could not find '%s' plugin root in runtimepath.", plugin_name)
  return nil
end

local function run_file_logic(core_opts)
  local log = uep_log.get()

  local uep_root = get_plugin_root("UEP")
  local unl_root = get_plugin_root("UNL")
  if not (uep_root and unl_root) then
    log.error("Could not find required plugin paths (UEP or UNL). Aborting file picker.")
    return
  end

  local cache_dir = unl_cache_core.get_cache_dir(uep_config.get())
  local script_path = vim.fs.joinpath(uep_root, "scripts", "generate_files.lua")
  if vim.fn.filereadable(script_path) == 0 then
    log.error("generate_files.lua script not found at: %s", script_path)
    return
  end

  local script_args = {
    core_opts.scope,
    core_opts.deps_flag,
    vim.loop.cwd(),
    cache_dir,
  }

  log.info("Starting file picker via external script: %s", script_path)

  -- ▼▼▼【変更点】テストコードを削除し、dynamic_picker.pick の呼び出しを復活 ▼▼▼
  dynamic_picker.pick({
    title = " Source & Config Files",
    command = "nvim",
    args = {
      "--headless",
      "--cmd",
      "set runtimepath^=" .. vim.fn.fnameescape(unl_root) .. "," .. vim.fn.fnameescape(uep_root),
      "-l",
      script_path,
      unpack(script_args)
    },
    conf = uep_config.get(),
    logger_name = uep_log.name,
    on_submit = function(selection)
      -- selectionは文字列か、単一要素のテーブル { "line" } の可能性がある
      if not selection then return end
      
      local selected_line
      if type(selection) == 'table' then
        selected_line = selection[1] or selection.value
      else
        selected_line = selection
      end

      if not selected_line or selected_line == '' then return end

      -- スクリプトが出力した `display\tpath` 形式の文字列をパース
      local file_path = selected_line:match("[^\t]+$")

      if file_path and file_path ~= "" then
        log.debug("Opening file from picker selection: %s", file_path)
        pcall(vim.cmd.edit, vim.fn.fnameescape(file_path))
      else
        log.warn("Could not parse file path from picker selection: %s", selected_line)
      end
    end,
  })
end

function M.execute(opts)
  -- (この関数は変更ありません)
  opts = opts or {}
  local log = uep_log.get()
  local core_opts = {
    scope = opts.category or "Game",
    deps_flag = opts.deps_flag or "--no-deps",
  }
  if opts.has_bang then
    local refresh_scope = core_opts.scope
    local refresh_cmd = "UEP refresh! " .. refresh_scope
    log.info("Bang detected. Running '%s' first...", refresh_cmd)
    local sub_id
    sub_id = unl_events.subscribe(unl_types.ON_AFTER_REFRESH_COMPLETED, function()
      unl_events.unsubscribe(sub_id)
      log.info("Refresh completed. Now running file logic.")
      vim.schedule(function() run_file_logic(core_opts) end)
    end)
    vim.api.nvim_command(refresh_cmd)
  else
    run_file_logic(core_opts)
  end
end

return M
