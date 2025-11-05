-- lua/UEP/cmd/core/find_symbol.lua (共通化対応版)

local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local symbol_cache = require("UEP.cache.symbols")
local uep_context = require("UEP.context")
local unl_cache_core = require("UNL.cache.core")
local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local core_utils = require("UEP.cmd.core.utils") -- [!] 共通関数を使うために追加

local M = {}

local function get_symbol_cache_filepath(scope, deps_flag)
  local cache_dir = unl_cache_core.get_cache_dir(uep_config.get())
  if not cache_dir then return nil end
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end
  local project_name = unl_path.normalize(project_root):gsub("[\\/:]", "_")
  local scope_suffix = "_" .. scope:lower()
  local deps_suffix = ""
  if deps_flag == "--shallow-deps" then deps_suffix = "_shallowdeps"
  elseif deps_flag == "--no-deps" then deps_suffix = "_nodeps"
  else deps_suffix = "_deepdeps" end
  local filename = project_name .. ".symbols" .. scope_suffix .. deps_suffix .. ".cache.json"
  return vim.fs.joinpath(cache_dir, "cmd", filename)
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

local SYMBOL_CACHE_MAGIC = "UEP Symbol Cache V2"
local SYMBOL_CACHE_VERSION = "2.0"

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
    uep_context.set(context_key, symbol_list)
    log.info("Saved %d symbols to cache (scope=%s, deps=%s): %s", #symbol_list, scope, deps_flag, path)
    return true
end

local function load_symbol_list(scope, deps_flag)
    local log = uep_log.get()
    local context_key = get_context_key(scope, deps_flag)
    if not context_key then return nil end
    local cached_symbols = uep_context.get(context_key)
    if cached_symbols then
        log.debug("Loaded %d symbols from in-memory cache (scope=%s, deps=%s)", #cached_symbols, scope, deps_flag)
        return cached_symbols
    end
    local path = get_symbol_cache_filepath(scope, deps_flag)
    if not path or vim.fn.filereadable(path) == 0 then return nil end
    local file_data = unl_cache_core.load_json(path)
    if not file_data or file_data.magic_code ~= SYMBOL_CACHE_MAGIC or file_data.version ~= SYMBOL_CACHE_VERSION or
       not file_data.symbols or type(file_data.symbols) ~= "table" then
        log.warn("Symbol cache (scope=%s, deps=%s) is invalid or outdated. Ignoring & deleting: %s", scope, deps_flag, path)
        pcall(vim.loop.fs_unlink, path)
        return nil
    end
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
    if vim.fn.isdirectory(cmd_cache_dir) == 0 then return true end
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
            local filename = vim.fn.fnamemodify(path, ":t")
            local scope_deps = filename:match(project_prefix .. "(.-).cache.json")
            if scope_deps then
                local parts = vim.split(scope_deps, "_", { plain=true })
                if #parts >= 2 then
                    local scope = parts[1]
                    local deps_str = table.concat(parts, "_", 2)
                    local deps_flag = "--deep-deps"
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

-- 複数回の同時生成を防ぐためのフラグ
local generating_flags = {}

----------------------------------------------------------------------
-- ▼▼▼ [削除] ローカルの open_file_and_jump ヘルパー関数 (約70行) を削除 ▼▼▼
----------------------------------------------------------------------
-- local function open_file_and_jump(target_file_path, symbol_name)
--   ... (中身全体を削除) ...
-- end
----------------------------------------------------------------------
-- ▲▲▲ [削除] ここまで ▲▲▲

----------------------------------------------------------------------
-- ヘルパー関数: シンボルリストをフィルタリングしてピッカー表示
----------------------------------------------------------------------
local function process_symbol_list(all_symbols_data, opts)
  local log = uep_log.get()
  local symbol_type = opts.symbol_type -- "class", "struct", or "enum"
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

  local scope_display = scope:gsub("^%l", string.upper)
  local deps_display = ""
  if deps_flag == "--shallow-deps" then deps_display = " (Shallow)"
  elseif deps_flag == "--no-deps" then deps_display = " (No Deps)"
  else deps_display = " (Deep)" end

  local picker_title = ("Select %s [%s%s]"):format(
                         symbol_type:gsub("^%l", string.upper),
                         scope_display,
                         deps_display)

  unl_picker.pick({
    kind = "uep_select_" .. symbol_type,
    title = picker_title,
    items = filtered_list,
    conf = uep_config.get(),
    preview_enabled = true,
    on_submit = function(selected_info)
      if selected_info and selected_info.file_path and selected_info.class_name then
        -- ▼▼▼ [修正] core_utils の関数を呼び出す ▼▼▼
        core_utils.open_file_and_jump(selected_info.file_path, selected_info.class_name)
        -- ▲▲▲ 修正完了 ▲▲▲
      end
    end,
  })
end

----------------------------------------------------------------------
-- ヘルパー関数: キャッシュを生成して保存する
----------------------------------------------------------------------
local function generate_and_save_symbol_cache(opts, callback)
  -- ( ... 変更なし ... )
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

  derived_core.get_all_classes(opts, function(all_symbols)
    generating_flags[generation_key] = nil

    if all_symbols then
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
end

----------------------------------------------------------------------
-- 公開API関数 (find_and_jump)
----------------------------------------------------------------------
function M.find_and_jump(opts)
  -- ( ... 変更なし ... )
  opts = opts or {}
  local log = uep_log.get()
  opts.scope = opts.scope or "runtime"
  opts.deps_flag = opts.deps_flag or "--deep-deps"

  local execute_logic = function(symbols_list)
     process_symbol_list(symbols_list, opts)
  end

  if opts.has_bang then
    log.info("Bang detected. Regenerating symbol cache (scope=%s, deps=%s)...", opts.scope, opts.deps_flag)
    generate_and_save_symbol_cache(opts, execute_logic)
    return
  end

  local cached_symbols = load_symbol_list(opts.scope, opts.deps_flag)

  if cached_symbols then
    log.info("Using existing symbol cache (scope=%s, deps=%s).", opts.scope, opts.deps_flag)
    execute_logic(cached_symbols)
    return
  end

  log.info("Symbol cache not found (scope=%s, deps=%s). Generating...", opts.scope, opts.deps_flag)
  generate_and_save_symbol_cache(opts, execute_logic)
end

return M
