-- lua/UEP/cmd/core/find_symbol.lua (files キャッシュ戦略版)

local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local symbol_cache = require("UEP.cache.symbols") -- キャッシュモジュール

local M = {}

-- 複数回の同時生成を防ぐためのフラグ
local is_generating_symbols_nodeps = false
local is_generating_symbols_alldeps = false

----------------------------------------------------------------------
-- ヘルパー関数: ファイルを開いてジャンプ (先行宣言スキップ・改訂版)
----------------------------------------------------------------------
local function open_file_and_jump(target_file_path, symbol_name)
  local log = uep_log.get()
  log.info("Jumping to definition in: %s", target_file_path)
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target_file_path))
  if not ok then
    return log.error("Failed to open file: %s", tostring(err))
  end
  local file_content = vim.fn.readfile(target_file_path)
  local line_number = 1
  local search_pattern_class = "class " .. symbol_name
  local search_pattern_struct = "struct " .. symbol_name
  for i, line in ipairs(file_content) do
    local class_match_start, _ = line:find(search_pattern_class, 1, true)
    local struct_match_start, _ = line:find(search_pattern_struct, 1, true)
    if class_match_start or struct_match_start then
      local trimmed_line = line:match("^%s*(.-)%s*$")
      if not trimmed_line:match(";%s*$") then
        line_number = i
        log.debug("Definition found on line %d: %s", i, line)
        break
      end
    end
  end
  vim.fn.cursor(line_number, 0)
  vim.cmd("normal! zz")
end

----------------------------------------------------------------------
-- ヘルパー関数: シンボルリストをフィルタリングしてピッカー表示
----------------------------------------------------------------------
local function process_symbol_list(all_symbols_data, opts)
  local log = uep_log.get()
  local symbol_type = opts.symbol_type

  if not all_symbols_data then
    return log.error("Failed to get symbol list. (Run :UEP refresh)")
  end

  local filtered_list = {}
  for _, info in ipairs(all_symbols_data) do
    if info.symbol_type == symbol_type then
      table.insert(filtered_list, info)
    end
  end

  if #filtered_list == 0 then
    -- [!] ログメッセージにスコープとフラグを追加
    return log.warn("No %ss found in the project cache (%s, %s).", symbol_type, opts.scope, opts.deps_flag or "--no-deps")
  end

  local title_scope = opts.scope or "Game"
  local title_deps = (opts.deps_flag == "--all-deps") and " (All Deps)" or ""
  local picker_title = ("Select %s to Open [%s%s]"):format(
                         symbol_type:gsub("^%l", string.upper),
                         title_scope,
                         title_deps)

  unl_picker.pick({
    kind = "uep_select_" .. symbol_type,
    title = picker_title,
    items = filtered_list,
    conf = uep_config.get(),
    preview_enabled = true,
    on_submit = function(selected_info)
      if selected_info and selected_info.file_path and selected_info.class_name then
        open_file_and_jump(selected_info.file_path, selected_info.class_name)
      end
    end,
  })
end

----------------------------------------------------------------------
-- ヘルパー関数: キャッシュを生成して保存する
----------------------------------------------------------------------
local function generate_and_save_symbol_cache(opts, callback)
  local log = uep_log.get()
  local deps_flag = opts.deps_flag or "--no-deps"

  local is_generating_flag = (deps_flag == "--all-deps") and is_generating_symbols_alldeps or is_generating_symbols_nodeps
  if is_generating_flag then
    return log.info("Symbol cache generation (%s) is already in progress.", deps_flag)
  end

  if deps_flag == "--all-deps" then is_generating_symbols_alldeps = true else is_generating_symbols_nodeps = true end

  -- vim.notify(("UEP: Generating symbol cache (%s)..."):format(deps_flag))
  log.info("Generating symbol cache (%s)...", deps_flag)

  -- 依存関係フィルタリング対応版の get_all_classes を呼び出す
  derived_core.get_all_classes(opts, function(all_symbols)
    if deps_flag == "--all-deps" then is_generating_symbols_alldeps = false else is_generating_symbols_nodeps = false end

    if all_symbols then
      symbol_cache.save(all_symbols, opts.scope, deps_flag) -- deps_flag を渡して保存
      -- vim.notify(("UEP: Symbol cache generated (%s)."):format(deps_flag))
      log.info("Symbol cache generation (%s) complete.", deps_flag)
      if callback then callback(all_symbols) end
    else
      log.error("Failed to generate symbol list (%s).", deps_flag)
      -- vim.notify(("UEP: Failed to generate symbol cache (%s)."):format(deps_flag), vim.log.levels.ERROR)
      if callback then callback(nil) end
    end
  end)
end

----------------------------------------------------------------------
-- 公開API関数 (find_and_jump) - files キャッシュ戦略版
----------------------------------------------------------------------
---
-- クラス/構造体ピッカーを表示し、選択された定義にジャンプする
-- キャッシュ戦略は :UEP files と同様
-- @param opts table
--   opts.symbol_type (string): "class" or "struct"
--   opts.has_bang (boolean, optional): true でキャッシュ再生成
--   opts.scope (string, optional): "Game" or "Engine"
--   opts.deps_flag (string, optional): "--no-deps" or "--all-deps"
function M.find_and_jump(opts)
  opts = opts or {}
  local log = uep_log.get()
  opts.deps_flag = opts.deps_flag or "--no-deps"
  opts.scope = opts.scope or "Game"

  -- print(vim.inspect(opts))

  local execute_logic = function(symbols_list)
     process_symbol_list(symbols_list, opts)
  end

  -- CASE 1: Bang (!) -> キャッシュ再生成して表示
  if opts.has_bang then
    log.info("Bang detected. Regenerating symbol cache (%s)...", opts.deps_flag)
    generate_and_save_symbol_cache(opts, execute_logic)
    return
  end

  -- CASE 2: Bang なし -> キャッシュを探す
  local cached_symbols = symbol_cache.load(opts.scope, opts.deps_flag)

  -- CASE 2a: キャッシュが見つかった -> それを使って表示
  if cached_symbols then
    log.info("Using existing symbol cache (%s).", opts.deps_flag)
    execute_logic(cached_symbols)
    return
  end

  -- CASE 2b: キャッシュが見つからなかった -> 生成して表示
  log.info("Symbol cache (%s) not found. Generating...", opts.deps_flag)
  generate_and_save_symbol_cache(opts, execute_logic)
end

return M
