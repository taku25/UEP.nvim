-- lua/UEP/cmd/copy_path.lua
local unl_finder = require("UNL.finder")
local log = require("UEP.logger")

local M = {}

local function copy_to_clipboard(text, label)
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  log.get().info("Copied %s: %s", label, text)
end

local function get_path(opts)
  local p = (opts and opts.file_path and opts.file_path ~= "") and opts.file_path
    or vim.api.nvim_buf_get_name(0)
  if not p or p == "" then
    log.get().warn("No file in current buffer.")
    return nil
  end
  return p
end

--- 絶対パスをコピー (forward slash 統一)
-- 例: D:/MyProject/Source/MyModule/Public/MyClass.h
function M.copy_absolute(opts)
  local p = get_path(opts)
  if not p then return end
  local abs = vim.fn.fnamemodify(p, ":p"):gsub("\\", "/")
  copy_to_clipboard(abs, "absolute path")
end

--- cwd からの相対パスをコピー
-- 例: Source/MyModule/Public/SubDir/MyClass.h
function M.copy_cwd_relative(opts)
  local p = get_path(opts)
  if not p then return end
  local rel = vim.fn.fnamemodify(p, ":~:."):gsub("\\", "/")
  copy_to_clipboard(rel, "cwd-relative path")
end

--- モジュール名 + Public/Private + 以下のパスをコピー
-- 例: MyModule/Public/SubDir/MyClass.h
function M.copy_module_path(opts)
  local p = get_path(opts)
  if not p then return end

  local abs = vim.fn.fnamemodify(p, ":p"):gsub("\\", "/")
  local logger = log.get()

  local module_info = unl_finder.module.find_module(abs)
  if module_info then
    local module_root = module_info.root:gsub("\\", "/")
    local module_name = module_info.name or vim.fn.fnamemodify(module_root, ":t")

    if abs:find(module_root, 1, true) then
      local rel_from_module = abs:sub(#module_root + 2)
      copy_to_clipboard(module_name .. "/" .. rel_from_module, "module path")
      return
    end
  end

  -- フォールバック: cwd 相対
  logger.warn("Module not found, falling back to cwd-relative path.")
  local rel = vim.fn.fnamemodify(p, ":~:."):gsub("\\", "/")
  copy_to_clipboard(rel, "module path (cwd fallback)")
end

return M
