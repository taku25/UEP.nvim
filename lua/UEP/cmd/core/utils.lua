-- lua/UEP/cmd/core/utils.lua (UNL Integration Version)

local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local unl_project = require("UNL.project")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

M.categorize_path = function(path)
  if path:match("%.uproject$") then return "uproject" end
  if path:match("%.uplugin$") then return "uplugin" end
  if path:find("/Programs/", 1, true) or path:match("/Programs$") then return "programs" end
  if path:find("/Shaders/", 1, true) or path:match("/Shaders$") then return "shader" end
  if path:find("/Config/", 1, true) or path:match("/Config$") then return "config" end
  if path:find("/Content/", 1, true) or path:match("/Content$") then return "content" end
  if path:find("/Source/", 1, true) or path:match("/Source$") then return "source" end
  return "other"
end

--- UNL.project.get_maps に委譲
M.get_project_maps = function(start_path, on_complete)
  unl_project.get_maps(start_path, on_complete)
end

M.create_relative_path = function(file_path, base_path)
  if not file_path or not base_path then return tostring(file_path) end
  local norm_file = tostring(file_path):gsub("\\", "/")
  local norm_base = tostring(base_path):gsub("\\", "/")
  local file_parts = vim.split(norm_file, "/", { plain = true })
  local base_parts = vim.split(norm_base, "/", { plain = true })
  local common_len = 0
  for i = 1, math.min(#file_parts, #base_parts) do
    if file_parts[i]:lower() == base_parts[i]:lower() then common_len = i else break end
  end
  if common_len > 0 and common_len < #file_parts then
    local relative_parts = {}
    for i = common_len + 1, #file_parts do table.insert(relative_parts, file_parts[i]) end
    return table.concat(relative_parts, "/")
  end
  return file_path
end

M.find_module_for_path = function(file_path, all_modules_map)
  if not file_path or not all_modules_map then return nil end
  local normalized_path = unl_path.normalize(file_path)
  local best_match = nil; local longest_path = 0
  for _, module_meta in pairs(all_modules_map) do
    if module_meta.module_root then
      local normalized_root = unl_path.normalize(module_meta.module_root)
      if normalized_path:find(normalized_root, 1, true) and #normalized_root > longest_path then
        longest_path = #normalized_root; best_match = module_meta
      end
    end
  end
  return best_match
end

local plugin_root_cache = {}
function M.find_plugin_root(plugin_name)
  if not plugin_name or plugin_name == "" then return nil end
  if plugin_root_cache[plugin_name] then return plugin_root_cache[plugin_name] end
  
  local escaped_name = plugin_name:gsub("%.", "%%.")
  local search_pattern = "[/\\\\]" .. escaped_name .. "$"
  
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    if path:match(search_pattern) then
      plugin_root_cache[plugin_name] = path; return path
    end
  end
  return nil
end

function M.get_worker_script_path(script_name)
  local root = M.find_plugin_root("UEP.nvim")
  if not root then return nil end
  local worker_path = fs.joinpath(root, "scripts", script_name)
  return (vim.fn.filereadable(worker_path) == 1) and worker_path or nil
end

function M.open_file_and_jump(target_file_path, symbol_name, optional_line)
  local log = uep_log.get()
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target_file_path))
  if not ok then return log.error("Failed to open file: " .. tostring(err)) end
  
  -- もし行番号が指定されていれば、直接ジャンプする
  if optional_line and optional_line > 0 then
      vim.fn.cursor(optional_line, 0)
      vim.cmd("normal! zz")
      return
  end
  
  local file_content = vim.fn.readfile(target_file_path)
  local line_number = 1; local found = false
  
  local pattern_prefix = [[\.\{-}]]
  local pat_class  = pattern_prefix .. [[class\s\+\(.\{-}_API\s\+\)\?\<]] .. symbol_name .. [[\>]]
  local pat_struct = pattern_prefix .. [[struct\s\+\(.\{-}_API\s\+\)\?\<]] .. symbol_name .. [[\>]]
  local pat_enum   = pattern_prefix .. [[enum\s\+\(class\s\+\)\?\<]] .. symbol_name .. [[\>]]
  
  for i, line in ipairs(file_content) do
    if vim.fn.match(line, pat_class) >= 0 or vim.fn.match(line, pat_struct) >= 0 or vim.fn.match(line, pat_enum) >= 0 then
      local trimmed = line:match("^%s*(.-)%s*$")
      if not (trimmed:match(";%s*(//.*)?$") or trimmed:match(";%s*(/%*.*%*/)?%s*$")) then
         line_number = i; found = true; break
      end
    end
  end
  if not found then
      for i, line in ipairs(file_content) do
          if vim.fn.match(line, pat_class) >= 0 or vim.fn.match(line, pat_struct) >= 0 or vim.fn.match(line, pat_enum) >= 0 then
              line_number = i; break
          end
      end
  end
  vim.fn.cursor(line_number, 0); vim.cmd("normal! zz")
end

return M
