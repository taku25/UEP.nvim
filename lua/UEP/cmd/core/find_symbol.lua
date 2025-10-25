-- lua/UEP/cmd/core/find_symbol.lua (スコープ・モジュールキャッシュ対応版)

local derived_core = require("UEP.cmd.core.derived") -- ★ 修正済みの derived_core
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local symbol_cache = require("UEP.cache.symbols") -- ★ symbol_cache 自体も後で修正が必要かも？ (ファイル名生成部分)
local uep_context = require("UEP.context") -- ★ オンメモリキャッシュ用に追加
local unl_cache_core = require("UNL.cache.core") -- ★ キャッシュパス生成用に追加
local unl_finder = require("UNL.finder") -- ★ キャッシュパス生成用に追加
local unl_path = require("UNL.path") -- ★ キャッシュパス生成用に追加

local M = {}

-- ▼▼▼ キャッシュパス/コンテキストキー生成関数 (files.lua から流用・修正) ▼▼▼
local function get_symbol_cache_filepath(scope, deps_flag)
  local cache_dir = unl_cache_core.get_cache_dir(uep_config.get())
  if not cache_dir then return nil end
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end
  local project_name = unl_path.normalize(project_root):gsub("[\\/:]", "_")

  -- ファイル名: [プロジェクト名].symbols_[scope]_[deps].cache.json
  local scope_suffix = "_" .. scope:lower()
  local deps_suffix = ""
  if deps_flag == "--shallow-deps" then deps_suffix = "_shallowdeps"
  elseif deps_flag == "--no-deps" then deps_suffix = "_nodeps"
  else deps_suffix = "_deepdeps" end -- デフォルトは deep

  local filename = project_name .. ".symbols" .. scope_suffix .. deps_suffix .. ".cache.json"
  return vim.fs.joinpath(cache_dir, "cmd", filename) -- cmd サブディレクトリに保存
end

local function get_context_key(scope, deps_flag)
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end

  local scope_suffix = scope:lower()
  local deps_suffix = ""
  if deps_flag == "--shallow-deps" then deps_suffix = "shallow"
  elseif deps_flag == "--no-deps" then deps_suffix = "no"
  else deps_suffix = "deep" end

  return "symbol_cache::" .. project_root .. "::" .. scope_suffix .. "::" .. deps_suffix
end

-- ▼▼▼ symbol_cache.lua の load/save/delete をここで再実装 ▼▼▼
-- (symbol_cache.lua を削除またはリファクタリングする想定)
local SYMBOL_CACHE_MAGIC = "UEP Symbol Cache V2"
local SYMBOL_CACHE_VERSION = "2.0" -- 新しいスコープ/Deps対応バージョン

local function save_symbol_list(symbol_list, scope, deps_flag)
    local log = uep_log.get()
    local path = get_symbol_cache_filepath(scope, deps_flag)
    local context_key = get_context_key(scope, deps_flag)
    if not path or not context_key then return false end

    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

    local data_to_save = {
        magic_code = SYMBOL_CACHE_MAGIC,
        version = SYMBOL_CACHE_VERSION,
        symbols = symbol_list,
    }

    local ok, err = unl_cache_core.save_json(path, data_to_save)
    if not ok then
        log.error("Failed to save symbol cache (scope=%s, deps=%s): %s", scope, deps_flag, tostring(err))
        return false
    end
    uep_context.set(context_key, symbol_list) -- オンメモリにはシンボルリストのみ保存
    log.info("Saved %d symbols to cache (scope=%s, deps=%s): %s", #symbol_list, scope, deps_flag, path)
    return true
end

local function load_symbol_list(scope, deps_flag)
    local log = uep_log.get()
    local context_key = get_context_key(scope, deps_flag)
    if not context_key then return nil end

    -- 1. オンメモリキャッシュを確認
    local cached_symbols = uep_context.get(context_key)
    if cached_symbols then
        log.debug("Loaded %d symbols from in-memory cache (scope=%s, deps=%s)", #cached_symbols, scope, deps_flag)
        return cached_symbols
    end

    -- 2. ディスクキャッシュを確認
    local path = get_symbol_cache_filepath(scope, deps_flag)
    if not path or vim.fn.filereadable(path) == 0 then return nil end

    local file_data = unl_cache_core.load_json(path)

    if not file_data or file_data.magic_code ~= SYMBOL_CACHE_MAGIC or file_data.version ~= SYMBOL_CACHE_VERSION or
       not file_data.symbols or type(file_data.symbols) ~= "table" then
        log.warn("Symbol cache (scope=%s, deps=%s) is invalid or outdated. Ignoring & deleting: %s", scope, deps_flag, path)
        pcall(vim.loop.fs_unlink, path) -- 古い/不正なキャッシュは削除
        return nil
    end

    -- 3. オンメモリに保存して返す
    uep_context.set(context_key, file_data.symbols)
    log.debug("Loaded %d symbols from disk cache (scope=%s, deps=%s): %s", #file_data.symbols, scope, deps_flag, path)
    return file_data.symbols
end

local function delete_all_symbol_caches()
    local log = uep_log.get()
    local conf = uep_config.get()
    local base_dir = unl_cache_core.get_cache_dir(conf)
    if not base_dir then return false end
    local cmd_cache_dir = vim.fs.joinpath(base_dir, "cmd")
    if vim.fn.isdirectory(cmd_cache_dir) == 0 then return true end -- ディレクトリなければ成功

    local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
    if not project_root then return false end
    local project_prefix = unl_path.normalize(project_root):gsub("[\\/:]", "_") .. ".symbols_"

    local deleted_any = false
    local errors = {}
    local files = vim.fn.glob(vim.fs.joinpath(cmd_cache_dir, project_prefix .. "*.cache.json"), true, true)

    for _, path in ipairs(files) do
        local ok, err = pcall(vim.loop.fs_unlink, path)
        if ok then
            log.info("Deleted symbol cache file: %s", path)
            deleted_any = true
            -- 対応するオンメモリキャッシュもクリア (キーをファイル名から再構築 - 少し非効率)
            local filename = vim.fn.fnamemodify(path, ":t")
            local scope_deps = filename:match(project_prefix .. "(.-).cache.json")
            if scope_deps then
                local parts = vim.split(scope_deps, "_", { plain=true })
                if #parts >= 2 then
                    local scope = parts[1]
                    local deps_str = table.concat(parts, "_", 2) -- _shallowdeps など
                    local deps_flag = "--deep-deps" -- default
                    if deps_str == "shallowdeps" then deps_flag = "--shallow-deps"
                    elseif deps_str == "nodeps" then deps_flag = "--no-deps" end
                    local context_key = get_context_key(scope, deps_flag)
                    if context_key then uep_context.del(context_key) end
                end
            end
        else
            table.insert(errors, ("Failed to delete %s: %s"):format(path, tostring(err)))
        end
    end
    if #errors > 0 then log.error("Errors during symbol cache deletion:\n%s", table.concat(errors, "\n")) end
    return #errors == 0
end
-- ▲▲▲ キャッシュ管理関数ここまで ▲▲▲


-- 複数回の同時生成を防ぐためのフラグ (スコープ/Deps別管理)
local generating_flags = {} -- key = "scope::deps_flag"

----------------------------------------------------------------------
-- ヘルパー関数: ファイルを開いてジャンプ (先行宣言スキップ・改訂版)
----------------------------------------------------------------------
local function open_file_and_jump(target_file_path, symbol_name)
  local log = uep_log.get() -- Make sure uep_log is available in this scope
  log.info("Jumping to definition in: %s for symbol: %s", target_file_path, symbol_name)

  -- Attempt to open the file
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target_file_path))
  if not ok then
    return log.error("Failed to open file '%s': %s", target_file_path, tostring(err))
  end

  -- File opened successfully, now find the definition line
  local file_content = vim.fn.readfile(target_file_path)
  if vim.v.shell_error ~= 0 then
      log.warn("Could not read file content for jumping: %s", target_file_path)
      -- Go to line 1 as a fallback
      vim.fn.cursor(1, 0)
      vim.cmd("normal! zz")
      return
  end

  local line_number = 1 -- Default to the first line
  local found_definition = false

  -- Define search patterns (case-sensitive)
  -- Matches "class SYMBOL_NAME", "struct SYMBOL_NAME", potentially with API macro
  local symbol_pattern_base = "%f[%w_]" .. symbol_name .. "%f[%W]" -- Match whole word
  local search_pattern_class = "class%s+" .. "([%w_]+_API%s+)?" .. symbol_pattern_base
  local search_pattern_struct = "struct%s+" .. "([%w_]+_API%s+)?" .. symbol_pattern_base

  for i, line in ipairs(file_content) do
    -- Check for class or struct definition on the line
    local class_match_start = line:find(search_pattern_class)
    local struct_match_start = line:find(search_pattern_struct)

    if class_match_start or struct_match_start then
      -- Found a line containing "class SymbolName" or "struct SymbolName"

      -- Now, check if it's likely a forward declaration (ends with ';')
      local trimmed_line = line:match("^%s*(.-)%s*$") -- Trim leading/trailing whitespace

      -- Skip lines ending in ';' possibly followed by comments or whitespace
      if trimmed_line:match(";%s*(//.*)?$") or trimmed_line:match(";%s*(/%*.*%*/)?%s*$") then
         log.trace("Skipping potential forward declaration on line %d: %s", i, line)
      else
         -- Doesn't end in ';', assume it's the main definition
         line_number = i
         found_definition = true
         log.debug("Definition likely found on line %d: %s", i, line)
         break -- Stop searching after finding the first likely definition
      end
    end
  end

  if not found_definition then
      log.warn("Could not find exact definition line for '%s' in %s. Jumping to first occurrence or line 1.", symbol_name, target_file_path)
      -- If no non-forward declaration was found, still try to jump near the first mention.
      -- Re-search without the ';' check just to find *any* occurrence.
      for i, line in ipairs(file_content) do
          local class_match_start = line:find(search_pattern_class)
          local struct_match_start = line:find(search_pattern_struct)
          if class_match_start or struct_match_start then
              line_number = i
              break
          end
      end
  end

  -- Move cursor and center the view
  vim.fn.cursor(line_number, 0)
  vim.cmd("normal! zz")
end

----------------------------------------------------------------------
-- ヘルパー関数: シンボルリストをフィルタリングしてピッカー表示 (タイトル修正)
----------------------------------------------------------------------
local function process_symbol_list(all_symbols_data, opts)
  local log = uep_log.get()
  local symbol_type = opts.symbol_type -- "class" or "struct"
  local scope = opts.scope or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"

  if not all_symbols_data then
    return log.error("Failed to get symbol list (scope=%s, deps=%s). (Run :UEP refresh)", scope, deps_flag)
  end

  local filtered_list = {}
  for _, info in ipairs(all_symbols_data) do
    if info.symbol_type == symbol_type then
      table.insert(filtered_list, info)
    end
  end

  if #filtered_list == 0 then
    return log.warn("No %ss found in the cache for scope=%s, deps=%s.", symbol_type, scope, deps_flag)
  end

  -- ▼▼▼ ピッカータイトルを修正 ▼▼▼
  local scope_display = scope:gsub("^%l", string.upper)
  local deps_display = ""
  if deps_flag == "--shallow-deps" then deps_display = " (Shallow)"
  elseif deps_flag == "--no-deps" then deps_display = " (No Deps)"
  else deps_display = " (Deep)" end

  local picker_title = ("Select %s [%s%s]"):format(
                         symbol_type:gsub("^%l", string.upper),
                         scope_display,
                         deps_display)
  -- ▲▲▲ タイトル修正ここまで ▲▲▲

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
-- ヘルパー関数: キャッシュを生成して保存する (スコープ/Deps対応)
----------------------------------------------------------------------
local function generate_and_save_symbol_cache(opts, callback)
  local log = uep_log.get()
  local scope = opts.scope or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"
  local generation_key = scope .. "::" .. deps_flag

  if generating_flags[generation_key] then
    return log.info("Symbol cache generation (%s) is already in progress.", generation_key)
  end
  generating_flags[generation_key] = true

  vim.notify(("UEP: Generating symbol cache (Scope: %s, Deps: %s)..."):format(scope, deps_flag))
  log.info("Generating symbol cache (scope=%s, deps=%s)...", scope, deps_flag)

  -- ▼▼▼ 修正済みの derived_core.get_all_classes を呼び出す ▼▼▼
  derived_core.get_all_classes(opts, function(all_symbols)
    generating_flags[generation_key] = nil -- フラグ解除

    if all_symbols then
      -- ★ 新しい save_symbol_list を使う
      save_symbol_list(all_symbols, scope, deps_flag)
      vim.notify(("UEP: Symbol cache generated (Scope: %s, Deps: %s)."):format(scope, deps_flag))
      log.info("Symbol cache generation (%s) complete.", generation_key)
      if callback then callback(all_symbols) end
    else
      log.error("Failed to generate symbol list (%s).", generation_key)
      vim.notify(("UEP: Failed to generate symbol cache (%s). Check logs."):format(generation_key), vim.log.levels.ERROR)
      if callback then callback(nil) end
    end
  end)
  -- ▲▲▲ 呼び出し修正ここまで ▲▲▲
end

----------------------------------------------------------------------
-- 公開API関数 (find_and_jump) - 新スコープ・キャッシュ対応版
----------------------------------------------------------------------
---
-- クラス/構造体ピッカーを表示し、選択された定義にジャンプする
-- @param opts table
--   opts.symbol_type (string): "class" or "struct"
--   opts.has_bang (boolean, optional): true でキャッシュ再生成
--   opts.scope (string, optional): "game", "engine", "runtime"(default), ...
--   opts.deps_flag (string, optional): "--deep-deps"(default), ...
function M.find_and_jump(opts)
  opts = opts or {}
  local log = uep_log.get()
  -- ▼▼▼ スコープとDepsフラグのパース (デフォルト値設定) ▼▼▼
  opts.scope = opts.scope or "runtime"
  opts.deps_flag = opts.deps_flag or "--deep-deps"
  -- (バリデーションは省略。呼び出し元で行う想定)
  -- ▲▲▲ パース修正ここまで ▲▲▲

  local execute_logic = function(symbols_list)
     process_symbol_list(symbols_list, opts) -- opts をそのまま渡す
  end

  -- CASE 1: Bang (!) -> キャッシュ再生成して表示
  if opts.has_bang then
    log.info("Bang detected. Regenerating symbol cache (scope=%s, deps=%s)...", opts.scope, opts.deps_flag)
    -- ★ delete_all_symbol_caches() はここでは呼ばない方が良いかも？(影響範囲が大きすぎる)
    -- ★ 特定のスコープ/Depsのキャッシュだけ削除する方が安全だが、一旦再生成のみ
    generate_and_save_symbol_cache(opts, execute_logic)
    return
  end

  -- CASE 2: Bang なし -> キャッシュを探す
  -- ★ 新しい load_symbol_list を使う
  local cached_symbols = load_symbol_list(opts.scope, opts.deps_flag)

  -- CASE 2a: キャッシュが見つかった -> それを使って表示
  if cached_symbols then
    log.info("Using existing symbol cache (scope=%s, deps=%s).", opts.scope, opts.deps_flag)
    execute_logic(cached_symbols)
    return
  end

  -- CASE 2b: キャッシュが見つからなかった -> 生成して表示
  log.info("Symbol cache not found (scope=%s, deps=%s). Generating...", opts.scope, opts.deps_flag)
  generate_and_save_symbol_cache(opts, execute_logic)
end

return M
