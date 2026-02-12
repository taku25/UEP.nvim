-- lua/UEP/cmd/shaders.lua
local files_core = require("UEP.cmd.core.files")
local core_utils = require("UEP.cmd.core.utils")
local unl_picker = require("UNL.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")

local M = {}

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 1. スコープとDepsフラグのパース (デフォルトは "Full" が便利かと思いますが、一旦 Runtime に合わせます)
  -- シェーダーはEngine側のものを参照することも多いため、指定がなければ "full" にフォールバックするロジックもアリです
  local requested_scope = opts.scope or "full" 
  local requested_deps = opts.deps_flag or "--deep-deps"

  log.debug("Executing :UEP shaders with scope=%s, deps=%s", requested_scope, requested_deps)

  -- 2. ファイルリストの取得
  files_core.get_files({ scope = requested_scope, deps_flag = requested_deps }, function(ok, files_with_context)
    if not ok then
      return log.error("Failed to get file list for shaders.")
    end

    -- 3. シェーダーのみをフィルタリング
    local shader_files = {}
    for _, item in ipairs(files_with_context) do
      -- カテゴリが 'shader' であるか、拡張子が usf/ush であるものを収集
      if item.category == "shader" or item.file_path:match("%.us[hf]$") then
        table.insert(shader_files, item)
      end
    end

    if #shader_files == 0 then
      return log.warn("No shader files found (scope=%s).", requested_scope)
    end

    -- 4. 表示用の整形
    local picker_items = {}
    for _, item in ipairs(shader_files) do
      if item.module_root then
        local relative_path = core_utils.create_relative_path(item.file_path, item.module_root)
        table.insert(picker_items, {
          display = string.format("%s/%s (%s)", item.module_name, relative_path, item.module_name),
          value = item.file_path,
          filename = item.file_path,
        })
      else
        table.insert(picker_items, {
          display = item.file_path,
          value = item.file_path,
          filename = item.file_path,
        })
      end
    end

    table.sort(picker_items, function(a, b) return a.display < b.display end)

    -- 5. Picker 起動
    unl_picker.open({
      kind = "uep_shaders",
      title = " Shaders",
      items = picker_items,
      conf = uep_config.get(),
      preview_enabled = true,
      devicons_enabled = true,
      on_submit = function(selection)
        if selection and selection ~= "" then
          pcall(vim.cmd.edit, vim.fn.fnameescape(selection))
        end
      end,
    })
  end)
end

return M

