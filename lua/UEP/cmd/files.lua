-- lua/UEP/cmd/files.lua (新スコープ・新Depsフラグ対応版)

local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local uep_context = require("UEP.context")
local unl_finder = require("UNL.finder")
local unl_picker = require("UNL.backend.picker")
local core_files = require("UEP.cmd.core.files")
local core_utils = require("UEP.cmd.core.utils")

local M = {}

-- (is_generating_nodeps 等のキャッシュ生成フラグ ... 変更なし)
local is_generating_nodeps = false -- --no-deps 用 (スコープ別にする必要あり？ -> 後で検討)
local is_generating_shallowdeps = false -- --shallow-deps 用
local is_generating_deepdeps = false -- --deep-deps 用

-- ▼▼▼ キャッシュパス/コンテキストキー生成関数を修正 ▼▼▼
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
-- ▲▲▲ キャッシュパス/コンテキストキー修正ここまで ▲▲▲


-- ★追加: 全てのピッカーキャッシュを削除する関数 (hub.luaから呼ばれる)
function M.delete_all_picker_caches()
  local log = uep_log.get()
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return end

  -- コンテキストキーのプレフィックスで検索して削除
  local scopes = { "runtime", "game", "engine", "developer", "editor", "full" }
  local modes = { "source", "config", "programs", "shader" }
  local deps = { "--deep-deps", "--shallow-deps", "--no-deps" }

  for _, s in ipairs(scopes) do
    for _, d in ipairs(deps) do
      -- モードなし
      local key = get_context_key(s, d, nil)
      if key then uep_context.set(key, nil) end
      -- モードあり
      for _, m in ipairs(modes) do
        local key_mode = get_context_key(s, d, m)
        if key_mode then uep_context.set(key_mode, nil) end
      end
    end
  end
  log.debug("All file picker caches cleared.")
end

-- (show_picker, load_cache_from_file は引数に scope を追加)
local function show_picker(scope, deps_flag, mode)
  local log = uep_log.get()
  local context_key = get_context_key(scope, deps_flag, mode)
  if not context_key then return log.error("Could not determine context key for picker.") end

  local picker_items = uep_context.get(context_key)
  if not picker_items or #picker_items == 0 then
    return log.info("UEP files: no items for scope=%s, deps=%s, mode=%s (cache empty).", scope, deps_flag, tostring(mode))
  end

  local scope_display = scope:gsub("^%l", string.upper) -- Runtime -> Runtime
  local mode_display = mode and (" [" .. mode:gsub("^%l", string.upper) .. "]") or ""
  local deps_display = ""
  if deps_flag == "--shallow-deps" then deps_display = " (Shallow Deps)"
  elseif deps_flag == "--no-deps" then deps_display = " (No Deps)"
  else deps_display = " (Deep Deps)" end -- デフォルト

  unl_picker.pick({
    kind = "uep_file_picker",
    title = (" Files [%s%s]%s"):format(scope_display, mode_display, deps_display),
    items = picker_items,
    conf = uep_config.get(),
    preview_enabled = true, devicons_enabled = true,
    on_submit = function(selection)
      if not selection or selection == "" then return end
      local file_path = selection:match("[^\t]+$") -- value は "display\tfilepath" 形式
      if file_path and file_path ~= "" then pcall(vim.cmd.edit, vim.fn.fnameescape(file_path)) end
    end,
  })
end

-- (generate_and_load_cache は引数に scope を追加、コアロジック呼び出しを修正)
local function generate_and_load_cache(scope, deps_flag, mode, on_complete)
  local log = uep_log.get()

  -- スコープとDepsフラグの組み合わせで生成中フラグを管理 (より複雑になる)
  -- local is_generating_key = scope .. "::" .. deps_flag
  -- if is_generating[is_generating_key] then return log.info(...) end
  -- is_generating[is_generating_key] = true
  -- あまり複雑にしすぎず、Depsフラグだけで管理する？ -> 要検討
  local is_generating_flag
  if deps_flag == "--no-deps" then is_generating_flag = is_generating_nodeps
  elseif deps_flag == "--shallow-deps" then is_generating_flag = is_generating_shallowdeps
  else is_generating_flag = is_generating_deepdeps end

  if is_generating_flag then
    return log.info("Cache generation for %s is already in progress.", deps_flag)
  end

  if deps_flag == "--no-deps" then is_generating_nodeps = true
  elseif deps_flag == "--shallow-deps" then is_generating_shallowdeps = true
  else is_generating_deepdeps = true end

  vim.notify(("UEP: Generating file list cache (Scope: %s, Mode: %s, Deps: %s)..."):format(scope, tostring(mode), deps_flag))
  log.info("Generating file list cache (Scope: %s, Mode: %s, Deps: %s)...", scope, tostring(mode), deps_flag)

  -- ★★★ コアロジック呼び出し (後で core_files.get_files を修正する必要あり) ★★★
  core_files.get_files({ scope = scope, deps_flag = deps_flag, mode = mode }, function(ok, result_files_with_context)
    local items_to_cache = {} -- 先に初期化
    if ok and result_files_with_context then
      log.debug("Received %d files from core logic.", #result_files_with_context)
      for _, file_data in ipairs(result_files_with_context) do
          -- 表示ラベルと値を作成 (変更なし、ただし core_utils.create_relative_path が必要)
          -- ★ file_data に module_root と module_name が含まれていることを期待
          if file_data.file_path and file_data.module_root and file_data.module_name then
              local relative_path = core_utils.create_relative_path(file_data.file_path, file_data.module_root)
              local display_label = string.format("%s/%s (%s)", file_data.module_name, relative_path, file_data.module_name)
              table.insert(items_to_cache, {
                display = display_label,
                value = string.format("%s\t%s", display_label, file_data.file_path),
                filename = file_data.file_path,
              })
          else
              log.debug("UEP files: skipping entry with missing data: %s", vim.inspect(file_data))
          end
      end
    else
        -- エラーメッセージが "No components in DB" の場合はログを出さない
        if not (type(result_files_with_context) == "string" and result_files_with_context:find("No components in DB")) then
            log.error("Failed to get files from core logic: %s", tostring(result_files_with_context))
        end
        -- ok が false でも空のキャッシュを保存する？ -> 今回はしない
    end

    local context_key = get_context_key(scope, deps_flag, mode)
    if context_key then uep_context.set(context_key, items_to_cache) end

    -- 生成中フラグを解除
    if deps_flag == "--no-deps" then is_generating_nodeps = false
    elseif deps_flag == "--shallow-deps" then is_generating_shallowdeps = false
    else is_generating_deepdeps = false end

    if ok then
        log.info("Cache generation complete for scope=%s, mode=%s, deps=%s. Found %d items.", scope, tostring(mode), deps_flag, #items_to_cache)
      else
        vim.notify(("UEP: Failed to generate file list cache (Scope: %s, Mode: %s, Deps: %s). Check logs."):format(scope, tostring(mode), deps_flag), vim.log.levels.ERROR)
      end

      if on_complete then on_complete(ok) end
  end)
end

-- ▼▼▼ execute 関数を修正 ▼▼▼
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 1. スコープをパース (デフォルト: runtime)
  local requested_scope = "runtime"
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }
  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          log.warn("Invalid scope argument '%s'. Defaulting to 'runtime'.", opts.scope)
      end
  end

  -- 2. Depsフラグをパース (デフォルト: --deep-deps)
  local requested_deps = "--deep-deps"
  local valid_deps = { ["--deep-deps"]=true, ["--shallow-deps"]=true, ["--no-deps"]=true }
  if opts.deps_flag then
      local deps_lower = opts.deps_flag:lower()
      if valid_deps[deps_lower] then
          requested_deps = deps_lower
      else
          log.warn("Invalid deps flag '%s'. Defaulting to '--deep-deps'.", opts.deps_flag)
      end
  end

  -- 3. Modeをパース (デフォルト: nil)
  local requested_mode = nil
  local valid_modes = { source=true, config=true, programs=true, shader=true }
  if opts.mode then
      local mode_lower = opts.mode:lower()
      if valid_modes[mode_lower] then
          requested_mode = mode_lower
      else
          log.warn("Invalid mode argument '%s'. Ignoring.", opts.mode)
      end
  end

  log.info("Executing :UEP files with scope=%s, mode=%s, deps_flag=%s, bang=%s",
           requested_scope, tostring(requested_mode), requested_deps, tostring(opts.has_bang))

  -- 4. Bang (!) 処理 (全キャッシュ再生成は複雑なので、指定されたスコープ/Depsのみ再生成)
  if opts.has_bang then
    log.info("Bang detected. Regenerating cache for scope=%s, mode=%s, deps=%s...", requested_scope, tostring(requested_mode), requested_deps)
    generate_and_load_cache(requested_scope, requested_deps, requested_mode, function(ok)
      if ok then show_picker(requested_scope, requested_deps, requested_mode) end
    end)
    return
  end

  -- 5. 通常実行: オンメモリ -> ディスク -> 生成 の順で試行
  local context_key = get_context_key(requested_scope, requested_deps, requested_mode)
  if not context_key then return log.error("Not in a UEP-indexed project.") end

  if uep_context.get(context_key) then
    log.debug("Using in-memory cache for scope=%s, mode=%s, deps=%s.", requested_scope, tostring(requested_mode), requested_deps)
    return show_picker(requested_scope, requested_deps, requested_mode)
  end

  log.debug("In-memory cache miss. Generating cache for scope=%s, mode=%s, deps=%s...", requested_scope, tostring(requested_mode), requested_deps)
  generate_and_load_cache(requested_scope, requested_deps, requested_mode, function(gen_ok)
    if gen_ok then show_picker(requested_scope, requested_deps, requested_mode) end
  end)
end
-- ▲▲▲ execute 関数修正ここまで ▲▲▲

return M
