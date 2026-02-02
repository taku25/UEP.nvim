-- lua/UEP/cmd/files.lua (新スコープ・新Depsフラグ対応版)

local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local uep_context = require("UEP.context")
local unl_finder = require("UNL.finder")
local unl_picker = require("UNL.backend.picker")
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

local function show_picker(scope, deps_flag, mode, items_override)
  local log = uep_log.get()
  local context_key = get_context_key(scope, deps_flag, mode)
  if not context_key then return log.error("Could not determine context key for picker.") end

  local picker_items = items_override or uep_context.get(context_key)
  if not picker_items or #picker_items == 0 then
    return log.info("UEP files: no items for scope=%s, deps=%s, mode=%s (cache empty).", scope, deps_flag, tostring(mode))
  end

  local scope_display = scope:gsub("^%l", string.upper)
  local mode_display = mode and (" [" .. mode:gsub("^%l", string.upper) .. "]") or ""
  local deps_display = ""
  if deps_flag == "--shallow-deps" then deps_display = " (Shallow Deps)"
  elseif deps_flag == "--no-deps" then deps_display = " (No Deps)"
  else deps_display = " (Deep Deps)" end
  
  -- items_overrideがある場合はタイトルにフィルタ済みであることを示す
  local filter_suffix = items_override and " (Filtered)" or ""

  unl_picker.pick({
    kind = "uep_file_picker",
    title = (" Files [%s%s]%s%s"):format(scope_display, mode_display, deps_display, filter_suffix),
    items = picker_items,
    conf = uep_config.get(),
    preview_enabled = true, devicons_enabled = true,
    on_submit = function(selection)
      if not selection or selection == "" then return end
      local file_path = selection:match("[^\t]+$")
      if file_path and file_path ~= "" then pcall(vim.cmd.edit, vim.fn.fnameescape(file_path)) end
    end,
  })
end

local function generate_and_load_cache(scope, deps_flag, mode, on_complete)
  local log = uep_log.get()
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

  log.info("Generating file list cache (Scope: %s, Mode: %s, Deps: %s)...", scope, tostring(mode), deps_flag)

  core_files.get_files({ scope = scope, deps_flag = deps_flag, mode = mode }, function(ok, result_files_with_context)
    local items_to_cache = {}
    if ok and result_files_with_context then
      log.debug("Received %d files from core logic.", #result_files_with_context)
      for _, file_data in ipairs(result_files_with_context) do
          if file_data.file_path and file_data.module_root and file_data.module_name then
              local relative_path = core_utils.create_relative_path(file_data.file_path, file_data.module_root)
              local display_label = string.format("%s/%s (%s)", file_data.module_name, relative_path, file_data.module_name)
              table.insert(items_to_cache, {
                display = display_label,
                value = string.format("%s\t%s", display_label, file_data.file_path),
                filename = file_data.file_path,
              })
          end
      end
    else
        if not (type(result_files_with_context) == "string" and result_files_with_context:find("No components in DB")) then
            log.error("Failed to get files from core logic: %s", tostring(result_files_with_context))
        end
    end

    local context_key = get_context_key(scope, deps_flag, mode)
    if context_key then uep_context.set(context_key, items_to_cache) end

    if deps_flag == "--no-deps" then is_generating_nodeps = false
    elseif deps_flag == "--shallow-deps" then is_generating_shallowdeps = false
    else is_generating_deepdeps = false end

    if ok then
        log.info("Cache generation complete for scope=%s, mode=%s, deps=%s. Found %d items.", scope, tostring(mode), deps_flag, #items_to_cache)
      else
        log.error("Failed to generate file list cache (Scope: %s, Mode: %s, Deps: %s).", scope, tostring(mode), deps_flag)
      end

      if on_complete then on_complete(ok) end
  end)
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 引数のパース (filter_textを追加)
  local scope, mode, deps_flag, filter_text = parse_args(opts.args or {})
  
  -- opts.scope, opts.deps_flag, opts.mode 等が外部から渡されている場合は優先する（API呼び出し用）
  if opts.scope then scope = opts.scope:lower() end
  if opts.deps_flag then deps_flag = opts.deps_flag:lower() end
  if opts.mode then mode = opts.mode:lower() end

  log.debug("Executing :UEP files with scope=%s, mode=%s, deps_flag=%s, filter='%s', bang=%s",
    scope, tostring(mode), deps_flag, filter_text, tostring(opts.bang))

  -- Bang (!) 処理: キャッシュ強制再生成 (フィルタがある場合は無視、またはフィルタ付きで再検索)
  if opts.has_bang then
    if filter_text and filter_text ~= "" then
        -- フィルタがある場合のBangは「フィルタ付き検索の再実行」とみなす
        log.info("Searching files (Scope: %s, Mode: %s, Deps: %s, Filter: '%s')...", scope, tostring(mode), deps_flag, filter_text)
        core_files.search_files({ scope = scope, deps_flag = deps_flag, mode = mode }, filter_text, function(ok, result_files)
            if ok and result_files then
                local items = {}
                for _, file_data in ipairs(result_files) do
                    local relative_path = core_utils.create_relative_path(file_data.file_path, file_data.module_root)
                    local display_label = string.format("%s/%s (%s)", file_data.module_name, relative_path, file_data.module_name)
                    table.insert(items, {
                        display = display_label,
                        value = string.format("%s\t%s", display_label, file_data.file_path),
                        filename = file_data.file_path,
                    })
                end
                show_picker(scope, deps_flag, mode, items)
            else
                log.warn("No files found matching filter '%s'.", filter_text)
            end
        end)
        return
    else
        log.info("Bang detected. Regenerating cache for scope=%s, mode=%s, deps=%s...", scope, tostring(mode), deps_flag)
        generate_and_load_cache(scope, deps_flag, mode, function(ok)
            if ok then show_picker(scope, deps_flag, mode) end
        end)
        return
    end
  end
  
  -- フィルタがある場合: Rust側で検索して即時表示 (キャッシュしない)
  if filter_text and filter_text ~= "" then
      log.info("Searching files (Scope: %s, Mode: %s, Deps: %s, Filter: '%s')...", scope, tostring(mode), deps_flag, filter_text)
      core_files.search_files({ scope = scope, deps_flag = deps_flag, mode = mode }, filter_text, function(ok, result_files)
          if ok and result_files then
              local items = {}
              for _, file_data in ipairs(result_files) do
                  local relative_path = core_utils.create_relative_path(file_data.file_path, file_data.module_root)
                  local display_label = string.format("%s/%s (%s)", file_data.module_name, relative_path, file_data.module_name)
                  table.insert(items, {
                      display = display_label,
                      value = string.format("%s\t%s", display_label, file_data.file_path),
                      filename = file_data.file_path,
                  })
              end
              show_picker(scope, deps_flag, mode, items)
          else
              log.warn("No files found matching filter '%s'.", filter_text)
          end
      end)
      return
  end

  -- 通常実行 (全件キャッシュ利用)
  local context_key = get_context_key(scope, deps_flag, mode)
  if not context_key then return log.error("Not in a UEP-indexed project.") end

  if uep_context.get(context_key) then
    log.debug("Using in-memory cache for scope=%s, mode=%s, deps=%s.", scope, tostring(mode), deps_flag)
    return show_picker(scope, deps_flag, mode)
  end

  log.debug("In-memory cache miss. Generating cache for scope=%s, mode=%s, deps=%s...", scope, tostring(mode), deps_flag)
  generate_and_load_cache(scope, deps_flag, mode, function(gen_ok)
    if gen_ok then show_picker(scope, deps_flag, mode) end
  end)
end

return M