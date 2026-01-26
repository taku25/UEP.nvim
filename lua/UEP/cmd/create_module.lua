local log = require("UEP.logger")

local M = {}

function M.execute(opts)
  opts = opts or {}

  local function handle_module_path(module_path)
    local sanitized_input = module_path:gsub("\\", "/")
    local module_name = vim.fs.basename(sanitized_input)
    local subdir_path = vim.fs.dirname(sanitized_input)
    if vim.fn.isdirectory(subdir_path) ~= 0 then
      vim.print(module_name)
      vim.print(subdir_path)
    else
      vim.notify("Folder " .. subdir_path .. "does not exist.", "error")
    end
  end

  if opts.module_path then
    handle_module_path(opts.module_path)
  else
    local function ask_for_module_name_and_path()
      vim.ui.input({
        prompt = "Enter Module Name (e.g., MyModule or path/to/MyModule):",
        completion = "dir",
      }, function(user_input)
        if not user_input or user_input == "" then
          return log.get().info("Module creation canceled.")
        end
        handle_module_path(user_input)
      end)
    end
    ask_for_module_name_and_path()
  end
end

return M
