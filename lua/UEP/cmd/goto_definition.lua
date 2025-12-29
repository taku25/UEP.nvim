-- lua/UEP/cmd/goto_definition.lua (DB一元化版)

local core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")
local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_db = require("UEP.db.init")
local db_query = require("UEP.db.query")

local M = {}

----------------------------------------------------------------------
-- ヘルパー関数 (DB検索)
----------------------------------------------------------------------
local function find_symbol_in_module_db(module_name, symbol_name)
  local db = uep_db.get()
  if not db then return nil end
  local result = db_query.find_symbol_in_module(db, module_name, symbol_name)
  if result then return result.file_path end
  return nil
end

----------------------------------------------------------------------
-- メインAPI関数
----------------------------------------------------------------------

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- === PATH 1: Bang (!) が指定された場合 ===
  if opts.has_bang then
    log.info("Bang detected! Forcing symbol picker for definition jump.")
    
    derived_core.get_all_classes({},function(all_symbols_data)
      if not all_symbols_data or #all_symbols_data == 0 then
        return log.error("No symbols found. Please run :UEP refresh.")
      end

      unl_picker.pick({
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

  -- === PATH 2: Bangがない場合 (カーソル下の単語を検索) ===
  local symbol_name = vim.fn.expand("<cword>")
  if symbol_name == "" then return log.warn("No symbol under cursor.") end

  local current_buf_path = vim.api.nvim_buf_get_name(0)
  log.info("Attempting to find true definition for: '%s' (from %s)", symbol_name, current_buf_path)

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return log.error("Could not get project maps: %s. (Run :UEP refresh)", tostring(maps))
    end

    local current_module = core_utils.find_module_for_path(current_buf_path, maps.all_modules_map)
    if not current_module then
      log.warn("Could not determine current module. Falling back to LSP...")
      vim.lsp.buf.definition()
      return
    end

    local searched_modules = {}

    -- 【検索順序 1】現在のモジュール
    searched_modules[current_module.name] = true
    local found_path = find_symbol_in_module_db(current_module.name, symbol_name)
    if found_path then
      log.info("Found in current module: %s", current_module.name)
      return core_utils.open_file_and_jump(found_path, symbol_name)
    end

    -- 【検索順序 2】浅い依存関係 (Shallow Dependencies)
    log.debug("Searching shallow dependencies...")
    for _, mod_name in ipairs(current_module.shallow_dependencies or {}) do
      if not searched_modules[mod_name] then
        searched_modules[mod_name] = true
        found_path = find_symbol_in_module_db(mod_name, symbol_name)
        if found_path then
          log.info("Found in shallow dependency module: %s", mod_name)
          return core_utils.open_file_and_jump(found_path, symbol_name)
        end
      end
    end

    -- 【検索順序 3】深い依存関係 (Deep Dependencies)
    log.debug("Searching deep dependencies...")
    for _, mod_name in ipairs(current_module.deep_dependencies or {}) do
      if not searched_modules[mod_name] then
        searched_modules[mod_name] = true
        found_path = find_symbol_in_module_db(mod_name, symbol_name)
        if found_path then
          log.info("Found in deep dependency module: %s", mod_name)
          return core_utils.open_file_and_jump(found_path, symbol_name)
        end
      end
    end

    -- 【検索順序 4】LSPフォールバック
    log.warn("Symbol '%s' not found in UEP's dependency cache. Falling back to LSP...", symbol_name)
    vim.lsp.buf.definition()
  end)
end

return  M
