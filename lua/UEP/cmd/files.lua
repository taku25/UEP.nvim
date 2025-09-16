-- lua/UEP/cmd/files.lua (修正版)

local files_core = require("UEP.cmd.core.files")
local unl_picker = require("UNL.backend.picker")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_events = require("UNL.event.events")
local unl_types = require("UNL.event.types")

local M = {}

local function show_picker(items, project_root)
  if not items or #items == 0 then
    uep_log.get().info("No matching files found.", "info")
    return
  end
  local picker_items = {};
  local root_prefix = project_root .. "/"
  for _, file_path in ipairs(items) do
    table.insert(picker_items, {
      label = file_path:gsub(root_prefix, ""),
      value = { filename = file_path, text = file_path:gsub(root_prefix, "") }
    })
  end
  table.sort(picker_items, function(a, b) return a.label < b.label end)
  unl_picker.pick({
    kind = "file_location",
    title = " Source & Config Files",
    items = picker_items,
    preview_enabled = true,
    conf = uep_config.get(),
    logger_name = uep_log.name,
    on_submit = function(selection)
      if selection and selection.filename then
        pcall(vim.cmd.edit, selection.filename)
      end
    end
  })
end

-- ▼▼▼ メインロジックを全面的に書き直し ▼▼▼
local function run_file_logic(core_opts)
  local log = uep_log.get()
  log.info("Assembling file list with scope: '%s', deps: '%s'", core_opts.scope, core_opts.deps_flag)
  -- print(core_opts.deps_flag)

  files_core.get_merged_files_for_project(vim.loop.cwd(), core_opts, function(ok, merged_data)
    if not ok or not merged_data then
      log.error("Failed to assemble file list: %s", tostring(merged_data))
      return
    end

    local final_files = {}
    vim.list_extend(final_files, merged_data.files.source)
    vim.list_extend(final_files, merged_data.files.config)
    vim.list_extend(final_files, merged_data.files.shader)
    vim.list_extend(final_files, merged_data.files.programs)
    vim.list_extend(final_files, merged_data.files.other)

    local project_root = require("UNL.finder").project.find_project_root(vim.loop.cwd())
    show_picker(final_files, project_root)
  end)
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- STEP 1: ユーザーの入力を解釈し、デフォルト値を設定する
  local core_opts = {
    scope = opts.category or "Game", -- デフォルトスコープ
    deps_flag = opts.deps_flag or "--no-deps", -- デフォルトの依存関係
  }

  -- STEP 2: `!` (bang) があるかどうかで処理を分岐
  if opts.has_bang then
    -- `!` がある場合: refreshコマンドを実行し、完了を待つ
    local refresh_scope = core_opts.scope
    local refresh_cmd = "UEP refresh! " .. refresh_scope
    log.info("Bang detected. Running '%s' first...", refresh_cmd)
    
    -- refresh完了イベントを一度だけ購読する
    local sub_id
    sub_id = unl_events.subscribe(unl_types.ON_AFTER_REFRESH_COMPLETED, function()
      unl_events.unsubscribe(sub_id) -- イベントを受け取ったらすぐに購読解除
      log.info("Refresh completed. Now running file logic.")
      vim.schedule(function() -- `vim.schedule`で安全に次の処理を呼び出す
        run_file_logic(core_opts)
      end)
    end)
    
    -- コマンドを非同期で実行
    vim.api.nvim_command(refresh_cmd)
  else
    -- `!` がない場合: そのままファイルリストのロジックを実行
    run_file_logic(core_opts)
  end
end
-- ▲▲▲ ここまで ▲▲▲

return M
