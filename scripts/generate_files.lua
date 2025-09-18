-- scripts/generate_files.lua (安定版)

local scope = arg[1] or "Game"
local deps_flag = arg[2] or "--no-deps"
local cwd = arg[3] or vim.loop.cwd()
local cache_dir = arg[4]

if cache_dir then
  local unl_cache_core = require("UNL.cache.core")
  unl_cache_core.get_cache_dir = function()
    return cache_dir
  end
end

local files_core = require("UEP.cmd.core.files")
local core_utils = require("UEP.cmd.core.utils")

files_core.get_merged_files_for_project(cwd, { scope = scope, deps_flag = deps_flag }, function(ok, result)
  if not ok or not result then
    io.stderr:write("Error: Failed to get files. Reason: " .. tostring(result) .. "\n")
    vim.cmd.cquit()
    return
  end
  
  local files_with_context = result
  
  for _, file_data in ipairs(files_with_context) do
    local relative_path = core_utils.create_relative_path(file_data.file_path, file_data.module_root)
    -- 表示ラベルをここで組み立てる
    local display_label = string.format("%s/%s (%s)", file_data.module_name, relative_path, file_data.module_name)
    
    -- 出力形式を display\tpath に戻す
    local output_line = string.format("%s\t%s", display_label, file_data.file_path)

    io.write(output_line .. "\n")
    io.stdout:flush()
  end

  vim.cmd.quit()
end)
