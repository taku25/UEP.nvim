-- lua/UEP/cmd/goto_definition.lua
local unl_api = require("UNL.api")
local core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")
local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.picker")
local uep_config = require("UEP.config")

local M = {}

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- === PATH 1: Bang (!) が指定された場合 ===
  if opts.has_bang then
    log.info("Bang detected! Forcing symbol picker for definition jump.")
    derived_core.get_all_classes({}, function(all_symbols_data)
      if not all_symbols_data or #all_symbols_data == 0 then
        return log.error("No symbols found. Please run :UNL refresh.")
      end
      unl_picker.open({
        kind = "uep_select_symbol_to_jump",
        title = "Select Symbol (Class, Struct, or Enum) to Jump",
        items = all_symbols_data,
        conf = uep_config.get(),
        preview_enabled = true,
        on_submit = function(selected_symbol)
          if selected_symbol and selected_symbol.file_path and selected_symbol.class_name then
            core_utils.open_file_and_jump(selected_symbol.file_path, selected_symbol.class_name)
          end
        end,
      })
    end)
    return
  end

  -- === PATH 2: Bang なし — サーバー側 tree-sitter で解析 ===
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1       -- 0-indexed
  local character = cursor[2]      -- 0-indexed byte offset

  -- バッファの全テキストを取得
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  local file_path = vim.api.nvim_buf_get_name(bufnr)

  if content == "" then
    return log.warn("Buffer is empty.")
  end

  log.debug("GotoDefinition: requesting server at %d:%d in %s", line, character, file_path)

  unl_api.db.goto_definition({
    content   = content,
    line      = line,
    character = character,
    file_path = file_path ~= "" and file_path or nil,
  }, function(result)
    if result and result ~= vim.NIL and type(result) == "table" and result.file_path then
      log.info("Found definition: %s:%s", result.file_path, tostring(result.line_number))
      core_utils.open_file_and_jump(result.file_path, result.symbol_name, result.line_number)
    else
      -- フォールバック: LSP
      log.debug("GotoDefinition: server returned nil, falling back to LSP.")
      vim.lsp.buf.definition()
    end
  end)
end

return M
