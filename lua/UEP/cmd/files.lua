-- lua/UEP/cmd/files.lua (キャッシュをcmdサブフォルダに保存する最終版)

local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local uep_context = require("UEP.context")
local unl_cache_core = require("UNL.cache.core")
local unl_finder = require("UNL.finder")
local unl_picker = require("UNL.backend.picker")
local core_files = require("UEP.cmd.core.files")
local core_utils = require("UEP.cmd.core.utils")
local unl_path = require("UNL.path")

local M = {}

local is_generating_nodeps = false
local is_generating_alldeps = false

-- ▼▼▼【変更点 1/2】`cmd`サブフォルダに保存するようパスを修正 ▼▼▼
local function get_cache_filepath(deps_flag)
  local cache_dir = unl_cache_core.get_cache_dir(uep_config.get())
  if not cache_dir then
    return nil
  end
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    return nil
  end
  local project_name = unl_path.normalize(project_root):gsub("[\\/:]", "_")
  local suffix = (deps_flag == "--all-deps") and "_alldeps" or "_nodeps"
  local filename = project_name .. ".picker_files" .. suffix .. ".cache.json"
  
  -- `cmd`サブディレクトリをパスに含める
  return vim.fs.joinpath(cache_dir, "cmd", filename)
end

local function get_context_key(deps_flag)
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end
  local suffix = (deps_flag == "--all-deps") and "alldeps" or "nodeps"
  return "files_picker_cache::" .. project_root .. "::" .. suffix
end

local function show_picker(opts)
  local log = uep_log.get()
  local context_key = get_context_key(opts.deps_flag)
  if not context_key then return log.error("Could not determine context key for picker.") end

  local picker_items = uep_context.get(context_key)
  if not picker_items or #picker_items == 0 then
    return log.warn("File cache is empty or not loaded. Nothing to show.")
  end

  local title_suffix = (opts.deps_flag == "--all-deps") and " (All Deps)" or ""
  unl_picker.pick({
    kind = "uep_file_picker",
    title = " Source & Config Files" .. title_suffix,
    items = picker_items,
    conf = uep_config.get(),
    preview_enabled = true,
    devicons_enabled = true,
    on_submit = function(selection)
      if not selection or selection == "" then return end
      local file_path = selection:match("[^\t]+$")
      if file_path and file_path ~= "" then pcall(vim.cmd.edit, vim.fn.fnameescape(file_path)) end
    end,
  })
end

local function load_cache_from_file(opts, on_complete)
  local log = uep_log.get()
  local cache_path = get_cache_filepath(opts.deps_flag)
  local context_key = get_context_key(opts.deps_flag)
  if not (cache_path and context_key) then if on_complete then on_complete(false) end; return end

  vim.schedule(function()
    local json_string = table.concat(vim.fn.readfile(cache_path), "")
    if vim.v.shell_error ~= 0 or json_string == "" then
      if on_complete then on_complete(false) end; return
    end
    local ok, items_table = pcall(vim.json.decode, json_string)
    if not ok or type(items_table) ~= "table" then
      if on_complete then on_complete(false) end; return
    end
    uep_context.set(context_key, items_table)
    if on_complete then on_complete(true) end
  end)
end

-- ▼▼▼【変更点 2/2】書き込み前にディレクトリを自動作成する処理を追加 ▼▼▼
local function generate_and_load_cache(opts, on_complete)
  local log = uep_log.get()
  local is_all_deps = opts.deps_flag == "--all-deps"
  
  if (is_all_deps and is_generating_alldeps) or (not is_all_deps and is_generating_nodeps) then
    return log.info("Cache generation for %s is already in progress.", opts.deps_flag)
  end

  if is_all_deps then is_generating_alldeps = true else is_generating_nodeps = true end
  vim.notify(("UEP: Generating file cache (%s)..."):format(opts.deps_flag))

  core_files.get_merged_files_for_project(vim.loop.cwd(), opts, function(ok, result)
    if ok and result then
      local items_to_cache = {}
      for _, file_data in ipairs(result) do
        local relative_path = core_utils.create_relative_path(file_data.file_path, file_data.module_root)
        local display_label = string.format("%s/%s (%s)", file_data.module_name, relative_path, file_data.module_name)
        table.insert(items_to_cache, {
          display = display_label,
          value = string.format("%s\t%s", display_label, file_data.file_path),
          filename = file_data.file_path,
        })
      end
      local cache_path = get_cache_filepath(opts.deps_flag)
      if cache_path then
        -- 親ディレクトリ(`cmd`)が存在しない場合に自動で作成する
        vim.fn.mkdir(vim.fn.fnamemodify(cache_path, ":h"), "p")
        vim.fn.writefile({ vim.json.encode(items_to_cache) }, cache_path)
      end
      local context_key = get_context_key(opts.deps_flag)
      if context_key then uep_context.set(context_key, items_to_cache) end
    end
    
    if is_all_deps then is_generating_alldeps = false else is_generating_nodeps = false end
    if on_complete then on_complete(ok) end
  end)
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()
  local core_opts = {
    scope = opts.category or "Game",
    deps_flag = opts.deps_flag or "--no-deps",
  }

  if opts.has_bang then
    log.info("Bang detected. Regenerating both --no-deps and --all-deps caches.")
    local no_deps_opts = vim.deepcopy(core_opts); no_deps_opts.deps_flag = "--no-deps"
    local all_deps_opts = vim.deepcopy(core_opts); all_deps_opts.deps_flag = "--all-deps"
    local primary_opts = (core_opts.deps_flag == "--all-deps") and all_deps_opts or no_deps_opts
    generate_and_load_cache(primary_opts, function(ok)
      if ok then show_picker(primary_opts) end
    end)
    local secondary_opts = (core_opts.deps_flag == "--all-deps") and no_deps_opts or all_deps_opts
    vim.schedule(function()
      generate_and_load_cache(secondary_opts)
    end)
    return
  end

  local context_key = get_context_key(core_opts.deps_flag)
  if not context_key then return log.error("Not in a UEP-indexed project.") end

  if uep_context.get(context_key) then
    return show_picker(core_opts)
  end

  local cache_path = get_cache_filepath(core_opts.deps_flag)
  if cache_path and vim.loop.fs_stat(cache_path) then
    return load_cache_from_file(core_opts, function(ok)
      if ok then show_picker(core_opts) end
    end)
  end

  generate_and_load_cache(core_opts, function(ok)
    if ok then show_picker(core_opts) end
  end)
end

return M
