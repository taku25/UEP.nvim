-- lua/UEP/cmd/goto_definition.lua (モジュールキャッシュ対応版)

-- 必要なモジュールをrequire
local core_utils = require("UEP.cmd.core.utils")
-- local files_cache_manager = require("UEP.cache.files") -- [!] 削除
local module_cache = require("UEP.cache.module") -- [!] 追加
local uep_log = require("UEP.logger")
local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")

local M = {} -- あなたのAPIモジュール

----------------------------------------------------------------------
-- ヘルパー関数 (修正)
----------------------------------------------------------------------

---
-- 特定のモジュールのキャッシュ内からシンボルを探すヘルパー
-- @param module_meta table UEPのモジュールメタデータ
-- @param symbol_name string 探したいクラス名
-- @return string|nil 見つかったファイルのフルパス
local function find_symbol_in_module_cache(module_meta, symbol_name)
  if not module_meta then return nil end
  -- [!] モジュールキャッシュをロード
  local mod_cache = module_cache.load(module_meta)
  
  if mod_cache and mod_cache.header_details then
    for file_path, details in pairs(mod_cache.header_details) do
      if details.classes then
        for _, class_info in ipairs(details.classes) do
          if class_info.class_name == symbol_name then
            return file_path -- 見つかった
          end
        end
      end
    end
  end
  return nil -- 見つからなかった
end

---
-- ファイルを開き、シンボルの定義行にジャンプするヘルパー (先行宣言スキップ・改訂版)
-- (この関数は変更なし)
local function open_file_and_jump(target_file_path, symbol_name)
  local log = uep_log.get()
  log.info("Found definition in: %s", target_file_path)
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target_file_path))
  if not ok then
    return log.error("Failed to open file: %s", tostring(err))
  end

  local file_content = vim.fn.readfile(target_file_path)
  local line_number = 1 -- デフォルトはファイルの先頭

  -- まずはシンプルな検索パターンに戻す
  local search_pattern_class = "class " .. symbol_name
  local search_pattern_struct = "struct " .. symbol_name

  for i, line in ipairs(file_content) do
    -- 1. まず、クラス名 or 構造体名を含む行を探す (APIマクロは一旦無視)
    local class_match_start, class_match_end = line:find(search_pattern_class, 1, true)
    local struct_match_start, struct_match_end = line:find(search_pattern_struct, 1, true)

    if class_match_start or struct_match_start then
      -- 2. マッチした場合、その行が ';' で終わるかチェック (空白は無視)
      local trimmed_line = line:match("^%s*(.-)%s*$") -- 行頭・行末の空白を除去
      
      -- 行末が ';' で終わる -> 先行宣言なのでスキップ
      if trimmed_line:match(";%s*$") then
         log.debug("Skipping potential forward declaration on line %d: %s", i, line)
      else
         -- ';' で終わらない -> 本体定義とみなす！
         line_number = i
         log.debug("Definition found on line %d: %s", i, line)
         break -- 最初の本体定義を見つけたらループを抜ける
      end
    end
  end

  vim.fn.cursor(line_number, 0)
  vim.cmd("normal! zz")
end

----------------------------------------------------------------------
-- メインAPI関数 (Bang対応・モジュールキャッシュ検索)
----------------------------------------------------------------------

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- === PATH 1: Bang (!) が指定された場合 ===
  -- (この部分は 'derived_core' に依存しており、既にリファクタ済みなので変更なし)
  if opts.has_bang then
    log.info("Bang detected! Forcing class picker for definition jump.")
    
    derived_core.get_all_classes({},function(all_classes_data)
      if not all_classes_data or #all_classes_data == 0 then
        return log.error("No classes found. Please run :UDEV refresh.")
      end

      unl_picker.pick({
        kind = "uep_select_class_to_jump",
        title = "Select Class to Jump to Definition",
        items = all_classes_data,
        conf = uep_config.get(),
        preview_enabled = true,
        on_submit = function(selected_class)
          if selected_class and selected_class.file_path and selected_class.class_name then
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

    -- [!] 検索ロジックをモジュールベースに変更
    local searched_modules = {}

    -- 【検索順序 1】現在のモジュール
    searched_modules[current_module.name] = true
    local found_path = find_symbol_in_module_cache(current_module, symbol_name)
    if found_path then
      log.info("Found in current module: %s", current_module.name)
      return open_file_and_jump(found_path, symbol_name)
    end

    -- 【検索順序 2】浅い依存関係 (Shallow Dependencies)
    log.debug("Searching shallow dependencies...")
    for _, mod_name in ipairs(current_module.shallow_dependencies or {}) do
      if not searched_modules[mod_name] then
        searched_modules[mod_name] = true
        local dep_module = maps.all_modules_map[mod_name]
        found_path = find_symbol_in_module_cache(dep_module, symbol_name)
        if found_path then
          log.info("Found in shallow dependency module: %s", mod_name)
          return open_file_and_jump(found_path, symbol_name)
        end
      end
    end

    -- 【検索順序 3】深い依存関係 (Deep Dependencies)
    log.debug("Searching deep dependencies...")
    for _, mod_name in ipairs(current_module.deep_dependencies or {}) do
      if not searched_modules[mod_name] then
        searched_modules[mod_name] = true
        local dep_module = maps.all_modules_map[mod_name]
        found_path = find_symbol_in_module_cache(dep_module, symbol_name)
        if found_path then
          log.info("Found in deep dependency module: %s", mod_name)
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
