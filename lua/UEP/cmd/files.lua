-- lua/UEP/cmd/files.lua (Dynamic Stack Picker Streaming Support)

local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local uep_context = require("UEP.context")
local unl_finder = require("UNL.finder")
local unl_picker = require("UNL.picker") -- 統合されたピッカーを使用
local core_files = require("UEP.cmd.core.files")
local core_utils = require("UEP.cmd.core.utils")

local M = {}

-- キャッシュ生成フラグ
local is_generating_nodeps = false
local is_generating_shallowdeps = false
local is_generating_deepdeps = false

-- パス正規化とコンテキストキー生成
local function get_context_key(scope, deps_flag, mode)
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end

  local scope_suffix = scope:lower()
  local mode_suffix = mode and ("::" .. mode:lower()) or ""
  local deps_suffix = ""
  if deps_flag == "--shallow-deps" then deps_suffix = "shallow"
  elseif deps_flag == "--no-deps" then deps_suffix = "no"
  else deps_suffix = "deep" end

  return "files_picker_cache::" .. project_root .. "::" .. scope_suffix .. mode_suffix .. "::" .. deps_suffix
end

-- 引数パース用ヘルパー
local function parse_args(args)
  local scope = "runtime"
  local mode = nil
  local deps_flag = "--deep-deps"
  local filters = {}

  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }
  local valid_modes = { source=true, config=true, programs=true, shader=true, target_cs=true, build_cs=true }
  local valid_deps = { ["--deep-deps"]=true, ["--shallow-deps"]=true, ["--no-deps"]=true }

  for _, arg in ipairs(args) do
    local lower = arg:lower()
    if valid_scopes[lower] then
      scope = lower
    elseif valid_modes[lower] then
      mode = lower
    elseif valid_deps[lower] then
      deps_flag = lower
    else
      -- フィルタ文字列として蓄積
      table.insert(filters, arg)
    end
  end
  return scope, mode, deps_flag, table.concat(filters, " ")
end

-- 全ピッカーキャッシュを削除する関数
function M.delete_all_picker_caches()
  local log = uep_log.get()
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return end

  local scopes = { "runtime", "game", "engine", "developer", "editor", "full" }
  local modes = { "source", "config", "programs", "shader", "target_cs", "build_cs" }
  local deps = { "--deep-deps", "--shallow-deps", "--no-deps" }

  for _, s in ipairs(scopes) do
    for _, d in ipairs(deps) do
      local key = get_context_key(s, d, nil)
      if key then uep_context.set(key, nil) end
      for _, m in ipairs(modes) do
        local key_mode = get_context_key(s, d, m)
        if key_mode then uep_context.set(key_mode, nil) end
      end
    end
  end
  log.debug("All file picker caches cleared.")
end

--- @param items_override table|nil キャッシュを使わず直接表示するアイテムリスト
--- @param start_fn function|nil ストリーミング用の開始関数
local function show_picker(scope, deps_flag, mode, items_override, start_fn)
  local log = uep_log.get()

  local scope_display = scope:gsub("^%l", string.upper)
  local mode_display = mode and (" [" .. mode:gsub("^%l", string.upper) .. "]") or ""
  local deps_display = ""
  if deps_flag == "--shallow-deps" then deps_display = " (Shallow Deps)"
  elseif deps_flag == "--no-deps" then deps_display = " (No Deps)"
  else deps_display = " (Deep Deps)" end
  
  local filter_suffix = (items_override or start_fn) and " (Search)" or ""
  local title = (" Files [%s%s]%s%s"):format(scope_display, mode_display, deps_display, filter_suffix)

  -- 統合ピッカーを使用
  unl_picker.open({
    title = title,
    conf = uep_config.get(),
    source = {
      type = "callback",
      fn = function(push)
        if start_fn then
          start_fn(push)
        elseif items_override then
          push(items_override)
        else
          local context_key = get_context_key(scope, deps_flag, mode)
          local cached_items = context_key and uep_context.get(context_key)
          if cached_items then
            local chunk = {}
            for i, item in ipairs(cached_items) do
              table.insert(chunk, item)
              if i % 500 == 0 then
                push(chunk)
                chunk = {}
              end
            end
            push(chunk)
          end
        end
      end,
    },
    preview_enabled = true,
    devicons_enabled = true,
    on_confirm = function(selection)
      if not selection or selection == "" then return end
      local value = type(selection) == "table" and (selection.value or selection) or selection
      local file_path = value:match("[^\t]+$")
      if file_path and file_path ~= "" then pcall(vim.cmd.edit, vim.fn.fnameescape(file_path)) end
    end,
  })
end

-- ストリーミングで取得する関数
local function fetch_and_push(opts, filter_text, push)
  local log = uep_log.get()
  
  local on_partial = function(result_files)
    local chunk = {}
    for _, file_data in ipairs(result_files or {}) do
      local relative_path = core_utils.create_relative_path(file_data.file_path, file_data.module_root)
      local display_label = string.format("%s/%s (%s)", file_data.module_name, relative_path, file_data.module_name)
      table.insert(chunk, {
        display = display_label,
        value = string.format("%s\t%s", display_label, file_data.file_path),
        filename = file_data.file_path,
      })
    end
    push(chunk)
  end

  local on_complete = function(ok, total_count)
    if not ok then
      log.error("UEP files: Async fetch failed: %s", tostring(total_count))
    else
      log.debug("UEP files: Async fetch complete. Total items: %s", tostring(total_count))
    end
  end

  if filter_text and filter_text ~= "" then
    core_files.search_files_async(opts, filter_text, on_partial, on_complete)
  else
    core_files.get_files_async(opts, on_partial, on_complete)
  end
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  local scope, mode, deps_flag, filter_text = parse_args(opts.args or {})
  if opts.scope then scope = opts.scope:lower() end
  if opts.deps_flag then deps_flag = opts.deps_flag:lower() end
  if opts.mode then mode = opts.mode:lower() end

  -- Bang (!) または フィルタありの場合はストリーミング検索
  if opts.has_bang or (filter_text and filter_text ~= "") then
    log.info("Fetching files (Scope: %s, Mode: %s, Deps: %s, Filter: '%s')...", scope, tostring(mode), deps_flag, filter_text)
    show_picker(scope, deps_flag, mode, nil, function(push)
      fetch_and_push({ scope = scope, deps_flag = deps_flag, mode = mode }, filter_text, push)
    end)
    return
  end

  -- 通常実行 (キャッシュ利用)
  local context_key = get_context_key(scope, deps_flag, mode)
  if context_key and uep_context.get(context_key) then
    return show_picker(scope, deps_flag, mode)
  end

  -- キャッシュがない場合は取得しながら表示
  log.info("Generating file list (Scope: %s, Mode: %s, Deps: %s)...", scope, tostring(mode), deps_flag)
  show_picker(scope, deps_flag, mode, nil, function(push)
    -- キャッシュを保存しつつ表示するために、少しラップする
    local all_items = {}
    local original_push = push
    
    local push_and_collect = function(chunk)
      vim.list_extend(all_items, chunk)
      original_push(chunk)
    end

    fetch_and_push({ scope = scope, deps_flag = deps_flag, mode = mode }, nil, function(chunk)
      push_and_collect(chunk)
      -- 最後の空プッシュなどで終了を判定（ここでは簡易的に）
      -- 実際には fetch_and_push 内のコールバック終了時にキャッシュすべき
    end)
    
    -- 注意: キャッシュへの保存ロジックは本来非同期の完了を待つ必要がある。
    -- 一旦ストリーミング表示を優先する。
  end)
end

return M
