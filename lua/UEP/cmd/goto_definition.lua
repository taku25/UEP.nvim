-- lua/UEP/cmd/goto_definition.lua (RPC Optimized)
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

  -- === PATH 2: Bangがない場合 (カーソル下の単語を検索) ===
  local symbol_name = vim.fn.expand("<cword>")
  if symbol_name == "" then return log.warn("No symbol under cursor.") end

  local current_buf_path = vim.api.nvim_buf_get_name(0)
  log.info("Attempting to find true definition for: '%s' (from %s)", symbol_name, current_buf_path)

  unl_api.project.get_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return log.error("Could not get project maps: %s. (Run :UNL refresh)", tostring(maps))
    end

    local current_module = core_utils.find_module_for_path(current_buf_path, maps.all_modules_map)
    
    -- 検索対象リストの作成 (順序: 現モジュール -> 浅い依存 -> 深い依存)
    local search_list = {}
    if current_module then
        table.insert(search_list, current_module.name)
        for _, m in ipairs(current_module.shallow_dependencies or {}) do table.insert(search_list, m) end
        for _, m in ipairs(current_module.deep_dependencies or {}) do table.insert(search_list, m) end
    end

    local function try_search(idx)
        if idx > #search_list then
            -- 全て失敗
            log.warn("Symbol '%s' not found in UEP's dependency cache. Falling back to LSP...", symbol_name)
            vim.lsp.buf.definition()
            return
        end

        local mod_name = search_list[idx]
        unl_api.db.find_symbol_in_module(mod_name, symbol_name, function(res, err)
            if res and res ~= vim.NIL and res.file_path then
                log.info("Found in module: %s", mod_name)
                core_utils.open_file_and_jump(res.file_path, symbol_name, res.line_number)
            else
                try_search(idx + 1)
            end
        end)
    end

    if #search_list > 0 then
        try_search(1)
    else
        -- モジュール特定不能
        log.warn("Could not determine current module. Falling back to LSP...")
        vim.lsp.buf.definition()
    end
  end)
end

return M
