local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_picker = require("UNL.picker")
local remote = require("UNL.db.remote")

local M = {}

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()
  local current_file = vim.api.nvim_buf_get_name(0)
  if current_file == "" then
    log.error("UEP depend_files: No file in current buffer")
    return
  end

  local recursive = false
  local game_only = false

  -- 引数の解析 (順不同でキーワード一致)
  if opts.args then
    for _, arg in ipairs(opts.args) do
      local lower = arg:lower()
      if lower == "recursive" or lower == "deep" then
        recursive = true
      elseif lower == "shallow" then
        recursive = false
      elseif lower == "game" then
        game_only = true
      elseif lower == "full" then
        game_only = false
      end
    end
  end

  log.info("Fetching dependent files for: %s (recursive: %s, game_only: %s)", 
    vim.fn.fnamemodify(current_file, ":t"), tostring(recursive), tostring(game_only))

  remote.get_depend_files(current_file, recursive, game_only, function(data_list, err)
    if err then
      log.error("UEP depend_files error: %s", tostring(err))
      return
    end

    if not data_list or #data_list == 0 then
      log.info("No dependent files found.")
      return
    end

    local items = {}
    for _, item in ipairs(data_list) do
      local full_path = item.file_path
      local module_name = item.module_name or "Unknown"
      local module_root = item.module_root
      
      -- モジュールルートからの相対パスを計算
      local relative_path = full_path
      if module_root and full_path:sub(1, #module_root) == module_root then
        relative_path = full_path:sub(#module_root + 1):gsub("^/", "")
      end

      -- UEP files スタイルの表示名を作成: [ModuleName] path/to/file.h
      local display = string.format("[%s] %s", module_name, relative_path)

      table.insert(items, {
        display = display,
        value = full_path,
        filename = full_path,
      })
    end

    -- 表示名でソート
    table.sort(items, function(a, b) return a.display < b.display end)

    unl_picker.open({
      title = " Depend Files: " .. vim.fn.fnamemodify(current_file, ":t"),
      conf = uep_config.get(),
      source = {
        type = "callback",
        fn = function(push)
          push(items)
        end,
      },
      preview_enabled = true,
      devicons_enabled = true,
      on_confirm = function(selection)
        if not selection then return end
        local file_path = type(selection) == "table" and (selection.value or selection) or selection
        vim.cmd.edit(vim.fn.fnameescape(file_path))
      end,
    })
  end)
end

return M
