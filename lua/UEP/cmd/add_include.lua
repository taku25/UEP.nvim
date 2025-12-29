-- lua/UEP/cmd/add_include.lua (H/CPP対応・最終版)

local derived_core = require("UEP.cmd.core.derived")
local core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_db = require("UEP.db.init")
local db_query = require("UEP.db.query")

local M = {}

-- (ヘルパー関数 format_include_path は変更ありません)
local function format_include_path(file_path, module_root)
  local normalized_path = file_path:gsub("\\", "/")
  local normalized_root = module_root:gsub("\\", "/")
  for _, folder in ipairs({ "Public", "Private", "Classes" }) do
    local search_base = normalized_root .. "/" .. folder .. "/"
    if normalized_path:find(search_base, 1, true) then
      return normalized_path:sub(#search_base + 1)
    end
  end
  local relative_path = core_utils.create_relative_path(file_path, module_root)
  return (relative_path ~= file_path) and relative_path or nil
end

---
-- 特定のクラス名の#include文を挿入するコアロジック
local function insert_include_for_class(target_class_name)
  local log = uep_log.get()
  log.info("Attempting to add #include for class: '%s'", target_class_name)

  local db = uep_db.get()
  if not db then return log.error("DB not available.") end

  local class_info = db_query.find_class_by_name(db, target_class_name)
  if not class_info then
      return log.warn("Class '%s' not found in DB.", target_class_name)
  end

  local target_header_path = class_info.file_path

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return log.error("Could not get project maps: %s", tostring(maps))
    end

    local module_info = core_utils.find_module_for_path(target_header_path, maps.all_modules_map)
    local include_path

    if module_info and module_info.module_root then
        include_path = format_include_path(target_header_path, module_info.module_root)
      else
        -- log.warn("Could not determine module for '%s'. Attempting engine header fallback.", target_header_path)
        local normalized_path = target_header_path:gsub("\\", "/")
        local base_folders = { "/Public/", "/Private/", "/Classes/" }
        for _, folder in ipairs(base_folders) do
          -- パスの中に Public/ や Private/ があるか探す
          local pos = normalized_path:find(folder, 1, true)
          if pos then
            -- 見つかった場合、そのフォルダ以降をインクルードパスとする
            include_path = normalized_path:sub(pos + #folder)
            log.info("Fallback successful. Using include path: %s", include_path)
            break
          end
        end
      end

      if not include_path then
        return log.error("Failed to format a relative include path for: %s", target_header_path)
      end
      -- ▲▲▲ ここまでが修正箇所です ▲▲▲

      local include_line = ('#include "%s"'):format(include_path)
      local buffer = vim.api.nvim_get_current_buf()
      local current_filename = vim.api.nvim_buf_get_name(buffer)
      local extension = vim.fn.fnamemodify(current_filename, ":e")
      local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)

      for _, line in ipairs(lines) do
        if line:find(include_path, 1, true) then return log.info("Include already exists.") end
      end

      if extension == "h" then
        local insertion_line_idx = -1
        for i, line in ipairs(lines) do
          if line:match('%.generated.h"') then
            insertion_line_idx = i - 1
            break
          end
        end
        if insertion_line_idx == -1 then
          return log.warn("Current file is a header, but could not find a '.generated.h' include.")
        end
        vim.api.nvim_buf_set_lines(buffer, insertion_line_idx, insertion_line_idx, false, { include_line })
        log.info("Successfully inserted into header: %s", include_line)

      elseif extension == "cpp" then
        local last_include_line_idx = -1
        for i = #lines, 1, -1 do
          if lines[i]:match("^%s*#include") then
            last_include_line_idx = i
            break
          end
        end
        local insertion_idx = (last_include_line_idx > 0) and last_include_line_idx or 0
        vim.api.nvim_buf_set_lines(buffer, insertion_idx, insertion_idx, false, { include_line })
        log.info("Successfully inserted into source file: %s", include_line)
      else
        log.warn("Cannot add include: current file is not a .h or .cpp file.")
      end
    end)
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- ケース1: bang (!) が指定された場合、強制的にPickerを表示
  if opts.has_bang then
    log.info("Bang detected! Forcing class picker.")
    derived_core.get_all_classes({},function(all_classes)
      if not all_classes or #all_classes == 0 then
        return log.error("No classes found. Please run :UEP refresh.")
      end

      local picker_items = {}
      for _, class_info in ipairs(all_classes) do
        table.insert(picker_items, {
          display = class_info.class_name,
          value = class_info.class_name,
          filename = class_info.file_path,
        })
      end

      unl_picker.pick({
        kind = "uep_select_class_to_include",
        title = "Select Class to #include",
        items = picker_items,
        conf = uep_config.get(),
        preview_enabled = true,
        on_submit = function(selected_class)
          if selected_class and selected_class ~= "" then
            insert_include_for_class(selected_class)
          end
        end,
      })
    end)
    return
  end

  -- ケース2: bangがない場合、引数またはカーソル下の単語を試す
  local target_class_name = opts.class_name or vim.fn.expand('<cword>')

  if target_class_name and target_class_name ~= "" then
    insert_include_for_class(target_class_name)
  else
    local msg = "No class name specified. Use ':UEP add_include!' to pick from a list."
    log.warn(msg)
  end
end

return M
