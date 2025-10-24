-- lua/UnrealDev/api.lua

-- 必要なモジュールをrequire
local core_utils = require("UEP.cmd.core.utils")
local files_cache_manager = require("UEP.cache.files")
local uep_log = require("UEP.logger")
local derived_core = require("UEP.cmd.core.derived") -- [!] bang対応で追加
local unl_picker = require("UNL.backend.picker")     -- [!] bang対応で追加
local uep_config = require("UEP.config")         -- [!] bang対応で追加

local M = {} -- あなたのAPIモジュール

----------------------------------------------------------------------
-- ヘルパー関数 (変更なし)
----------------------------------------------------------------------

---
-- 特定のコンポーネントのキャッシュ内からシンボルを探すヘルパー
-- @param component_meta table UEPのコンポーネントメタデータ
-- @param symbol_name string 探したいクラス名
-- @return string|nil 見つかったファイルのフルパス
local function find_symbol_in_component_cache(component_meta, symbol_name)
  if not component_meta then return nil end
  local files_cache = files_cache_manager.load_component_cache(component_meta)
  if files_cache and files_cache.header_details then
    for file_path, details in pairs(files_cache.header_details) do
      if details.classes then
        for _, class_info in ipairs(details.classes) do
          if class_info.class_name == symbol_name then
            return file_path
          end
        end
      end
    end
  end
  return nil
end

---
-- ファイルを開き、シンボルの定義行にジャンプするヘルパー
-- @param target_file_path string 開くファイル
-- @param symbol_name string ジャンプ先のシンボル名
local function open_file_and_jump(target_file_path, symbol_name)
  local log = uep_log.get()
  log.info("Found definition in: %s", target_file_path)
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target_file_path))
  if not ok then
    return log.error("Failed to open file: %s", tostring(err))
  end
  local file_content = vim.fn.readfile(target_file_path)
  local line_number = 1
  local search_pattern_class = "class " .. symbol_name
  local search_pattern_struct = "struct " .. symbol_name
  for i, line in ipairs(file_content) do
    if line:find(search_pattern_class, 1, true) or line:find(search_pattern_struct, 1, true) then
      line_number = i
      break
    end
  end
  vim.fn.cursor(line_number, 0)
  vim.cmd("normal! zz")
end

----------------------------------------------------------------------
-- メインAPI関数 (Bang対応版)
----------------------------------------------------------------------

---
-- カーソル下のシンボル、またはPickerから選択したクラスの
-- 「本当の定義ファイル」を検索してジャンプします。
-- @param opts table | nil
--   opts.has_bang (boolean): trueの場合、クラス選択ピッカーを起動する
--
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- === PATH 1: Bang (!) が指定された場合 ===
  if opts.has_bang then
    log.info("Bang detected! Forcing class picker for definition jump.")
    
    -- (UEP.cmd.core.derived)
    derived_core.get_all_classes(function(all_classes_data)
      if not all_classes_data or #all_classes_data == 0 then
        return log.error("No classes found. Please run :UDEV refresh.")
      end

      -- (UNL.backend.picker)
      unl_picker.pick({
        kind = "uep_select_class_to_jump",
        title = "Select Class to Jump to Definition",
        items = all_classes_data, -- get_all_classesが返すリストはPickerに最適化済み
        conf = uep_config.get(),
        preview_enabled = true,
        on_submit = function(selected_class)
          -- selected_class は { class_name = "...", file_path = "..." } というテーブル
          if selected_class and selected_class.file_path and selected_class.class_name then
            -- 選択されたクラスの定義にジャンプ
            open_file_and_jump(selected_class.file_path, selected_class.class_name)
          end
        end,
      })
    end)
    return -- Bang pathの処理はここで終了
  end

  -- === PATH 2: Bangがない場合 (カーソル下の単語を検索) ===
  local symbol_name = vim.fn.expand("<cword>")
  if symbol_name == "" then return log.warn("No symbol under cursor.") end

  local current_buf_path = vim.api.nvim_buf_get_name(0)
  log.info("Attempting to find true definition for: '%s' (from %s)", symbol_name, current_buf_path)

  -- (UEP.cmd.core.utils)
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return log.error("Could not get project maps: %s. (Run :UDEV refresh)", tostring(maps))
    end

    local current_module = core_utils.find_module_for_path(current_buf_path, maps.all_modules_map)
    if not current_module then
      log.warn("Could not determine current module. Falling back to LSP...")
      vim.lsp.buf.definition()
      return
    end

    local searched_components = {}

    -- 【検索順序 1】現在のモジュールが属するコンポーネント
    local current_comp_name = maps.module_to_component_name[current_module.name]
    local current_component = maps.all_components_map[current_comp_name]
    if current_component then
      searched_components[current_comp_name] = true
      local found_path = find_symbol_in_component_cache(current_component, symbol_name)
      if found_path then
        log.info("Found in current module's component: %s", current_comp_name)
        return open_file_and_jump(found_path, symbol_name)
      end
    end

    -- 【検索順序 2】浅い依存関係 (Shallow Dependencies)
    log.debug("Searching shallow dependencies...")
    for _, mod_name in ipairs(current_module.shallow_dependencies or {}) do
      local comp_name = maps.module_to_component_name[mod_name]
      if comp_name and not searched_components[comp_name] then
        searched_components[comp_name] = true
        local component = maps.all_components_map[comp_name]
        local found_path = find_symbol_in_component_cache(component, symbol_name)
        if found_path then
          log.info("Found in shallow dependency component: %s (Module: %s)", comp_name, mod_name)
          return open_file_and_jump(found_path, symbol_name)
        end
      end
    end

    -- 【検索順序 3】深い依存関係 (Deep Dependencies)
    log.debug("Searching deep dependencies...")
    for _, mod_name in ipairs(current_module.deep_dependencies or {}) do
      local comp_name = maps.module_to_component_name[mod_name]
      if comp_name and not searched_components[comp_name] then
        searched_components[comp_name] = true
        local component = maps.all_components_map[comp_name]
        local found_path = find_symbol_in_component_cache(component, symbol_name)
        if found_path then
          log.info("Found in deep dependency component: %s (Module: %s)", comp_name, mod_name)
          return open_file_and_jump(found_path, symbol_name)
        end
      end
    end

    -- 【検索順序 4】LSPフォールバック
    log.warn("Class '%s' not found in UEP's dependency cache. Falling back to LSP...", symbol_name)
    vim.lsp.buf.definition()
  end)
end

return M
