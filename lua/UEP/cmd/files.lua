-- lua/UEP/cmd/files.lua

local project_cache = require("UEP.cache.project")
local files_core    = require("UEP.cmd.files_core")
local unl_picker    = require("UNL.backend.picker")
local uep_log      = require("UEP.logger")
local uep_config      = require("UEP.config")
local refresh_cmd  = require("UEP.cmd.refresh")

local M = {}

-- Picker表示用のヘルパー関数
local function show_picker(items, project_root)
  if not items or #items == 0 then
    uep_log.get().info("No matching files found.", "info")
    return
  end
  local picker_items = {}; local root_prefix = project_root .. "/"
  for _, file_path in ipairs(items) do
    table.insert(picker_items, {
      label = file_path:gsub(root_prefix, ""),
      value = { filename = file_path, text = file_path:gsub(root_prefix, "") }
    })
  end
  table.sort(picker_items, function(a, b) return a.label < b.label end)
  unl_picker.pick({
    kind = "file_location", 
    title = "  Source & Config Files",
    items = picker_items,
    preview_enabled = true,
    conf = uep_config.get(),
    logger_name = uep_log.name,
    on_submit = function(selection)
      if selection and selection.filename then
        pcall(vim.cmd.edit, selection.filename)
      end
    end
  })
end

-- メインの実行関数
function M.execute(opts)
  local game_data = project_cache.load(vim.loop.cwd())
  if not game_data then
    uep_log.get().error("Project data not found. Run :UEP refresh first.")
    return
  end

  -- 1. 引数を解釈する
  local scope = "Game"
  local use_deep_deps = false
  if opts.category and (opts.category == "--all-deps" or opts.category == "--deep") then
    use_deep_deps = true
  elseif opts.category and (opts.category == "Game" or opts.category == "Engine") then
    scope = opts.category
    if opts.deps_flag and (opts.deps_flag == "--all-deps" or opts.deps_flag == "--deep") then
      use_deep_deps = true
    end
  end

  -- 2. !付きの場合の処理
  if opts.has_bang then
    uep_log.get().info(("Regenerating '%s' file cache..."):format(scope))
    -- refresh.executeを直接呼び出し、完了後にコールバックを実行
    refresh_cmd.execute({ type = scope }, function(ok)
      if ok then
        uep_log.get().info("Cache regenerated successfully. Displaying files.")
        -- 処理完了後、自分自身を再度呼び出す (ただし!は付けない)
        local new_opts = vim.deepcopy(opts)
        new_opts.has_bang = false
        M.execute(new_opts)
      else
        uep_log.get().error("Cache regeneration failed.")
      end
    end)
    return -- refresh処理の完了を待つため、ここで一旦終了
  end

  -- 3. 通常の処理 (キャッシュ読み込みと表示)
  local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil
  
  local all_modules = {}
  if game_data and game_data.modules then
    for name, meta in pairs(game_data.modules) do all_modules[name] = meta end
  end
  if engine_data and engine_data.modules then
    for name, meta in pairs(engine_data.modules) do
      if not all_modules[name] then all_modules[name] = meta end
    end
  end

  local base_modules = {}
  for name, meta in pairs(all_modules) do
    if meta.category == scope then base_modules[name] = true end
  end
  
  local final_module_names = {}
  for name in pairs(base_modules) do
    table.insert(final_module_names, name)
    local deps_key = use_deep_deps and "deep_dependencies" or "shallow_dependencies"
    if all_modules[name] and all_modules[name][deps_key] then
      for _, dep_name in ipairs(all_modules[name][deps_key]) do
        table.insert(final_module_names, dep_name)
      end
    end
  end

  local module_set = {}
  for _, name in ipairs(final_module_names) do module_set[name] = true end
  final_module_names = vim.tbl_keys(module_set)

  local final_files = files_core.get_files_from_cache({
    required_modules = final_module_names,
    project_root = game_data.root,
    engine_root = game_data.link_engine_cache_root,
    scope = scope, -- files_core にも scope を渡す
  })

  if not final_files then return end
  
  show_picker(final_files, game_data.root)
end

return M
