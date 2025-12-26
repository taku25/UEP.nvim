-- lua/UEP/cmd/core/utils.lua (カテゴリ分類を Programs 優先に戻す)

local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local uep_db = require("UEP.db.init")

local M = {}

-- ▼▼▼ 修正箇所 (ご指摘の通り、Programs を Source より先に戻します) ▼▼▼
-- ▼▼▼ 修正箇所 ▼▼▼
M.categorize_path = function(path)
  -- 1. ファイル拡張子による判定 (最優先)
  if path:match("%.uproject$") then return "uproject" end
  if path:match("%.uplugin$") then return "uplugin" end

  -- 2. 特殊ディレクトリによる判定 (優先度高)
  -- Pluginsフォルダの中にあったとしても、これらのフォルダ名が含まれていればそのカテゴリを優先する
  
  if path:find("/Programs/", 1, true) or path:match("/Programs$") then return "programs" end
  if path:find("/Shaders/", 1, true) or path:match("/Shaders$") then return "shader" end
  if path:find("/Config/", 1, true) or path:match("/Config$") then return "config" end
  if path:find("/Content/", 1, true) or path:match("/Content$") then return "content" end
  
  -- 3. Sourceディレクトリ (Plugins/xxx/Source もここでヒットする)
  if path:find("/Source/", 1, true) or path:match("/Source$") then return "source" end
  
  -- 4. その他
  -- 以前あった `if path:find("/Plugins/")` の判定は削除しました。
  -- Plugins内のファイルも上記の Shaders/Config/Source ルールで正しく分類されるべきであるためです。
  -- それらに該当しない Plugin 内のファイル (Resources等) は "other" とします。
  
  return "other"
end
-- ▲▲▲ 修正完了 ▲▲▲
-- ▲▲▲ 修正完了 ▲▲▲


-- (get_project_maps, create_relative_path, find_module_for_path は変更ありません)
-- (念のため、ファイル全体を以下に記載します)

M.get_project_maps = function(start_path, on_complete)
  local log = uep_log.get()
  log.debug("get_project_maps (DB) called...")
  local start_time = os.clock()

  local project_root = unl_finder.project.find_project_root(start_path)
  if not project_root then
    log.error("get_project_maps: Could not find project root.")
    return on_complete(false, "Could not find project root.")
  end

  local db = uep_db.get()
  if not db then
    log.error("get_project_maps: Could not open DB.")
    return on_complete(false, "DB not available.")
  end

  local components = db:eval("SELECT * FROM components") or {}
  if #components == 0 then
    log.warn("get_project_maps: No components in DB. Run :UEP refresh.")
    return on_complete(false, "No components in DB.")
  end

  local modules_rows = db:eval("SELECT * FROM modules") or {}

  local all_components_map = {}
  local all_modules_map = {}
  local module_to_component_name = {}
  local runtime_modules_map, developer_modules_map, editor_modules_map, programs_modules_map = {}, {}, {}, {}
  local game_name, engine_name

  for _, comp in ipairs(components) do
    all_components_map[comp.name] = {
      name = comp.name,
      display_name = comp.display_name,
      type = comp.type,
      owner_name = comp.owner_name,
      root_path = comp.root_path,
      uplugin_path = comp.uplugin_path,
      uproject_path = comp.uproject_path,
      engine_association = comp.engine_association,
    }
    if comp.type == "Game" then game_name = comp.name end
    if comp.type == "Engine" then engine_name = comp.name end
  end

  for _, row in ipairs(modules_rows) do
    local mod_meta = {
      name = row.name,
      type = row.type,
      scope = row.scope,
      module_root = row.root_path,
      path = row.build_cs_path,
      owner_name = row.owner_name,
      component_name = row.component_name,
    }

    all_modules_map[row.name] = mod_meta
    module_to_component_name[row.name] = row.component_name

    local t = (row.type or ""):lower()
    if t == "program" then programs_modules_map[row.name] = mod_meta
    elseif t == "developer" then developer_modules_map[row.name] = mod_meta
    elseif t:find("editor", 1, true) or t == "uncookedonly" then editor_modules_map[row.name] = mod_meta
    else runtime_modules_map[row.name] = mod_meta end
  end

  local end_time = os.clock()
  log.debug("get_project_maps finished in %.4f seconds (DB). Found %d modules across %d components.",
            end_time - start_time, vim.tbl_count(all_modules_map), vim.tbl_count(all_components_map))

  -- Engine rootは Engine コンポーネントの root_path を利用
  local engine_root = engine_name and all_components_map[engine_name] and all_components_map[engine_name].root_path or nil

  on_complete(true, {
    project_root = project_root,
    engine_root = engine_root,
    all_modules_map = all_modules_map,
    module_to_component_name = module_to_component_name,
    all_components_map = all_components_map,
    runtime_modules_map = runtime_modules_map,
    developer_modules_map = developer_modules_map,
    editor_modules_map = editor_modules_map,
    programs_modules_map = programs_modules_map,
    project_registry_info = nil,
    game_component_name = game_name,
    engine_component_name = engine_name,
  })
end


M.create_relative_path = function(file_path, base_path)
  if not file_path or not base_path then return file_path end
  local norm_file = file_path:gsub("\\", "/")
  local norm_base = base_path:gsub("\\", "/")
  local file_parts = vim.split(norm_file, "/", { plain = true })
  local base_parts = vim.split(norm_base, "/", { plain = true })
  local common_len = 0
  for i = 1, math.min(#file_parts, #base_parts) do
    if file_parts[i]:lower() == base_parts[i]:lower() then common_len = i else break end
  end
  if common_len > 0 and common_len < #file_parts then
    local relative_parts = {}
    for i = common_len + 1, #file_parts do table.insert(relative_parts, file_parts[i]) end
    return table.concat(relative_parts, "/")
  end
  return file_path
end

M.find_module_for_path = function(file_path, all_modules_map)
  if not file_path or not all_modules_map then return nil end
  local normalized_path = unl_path.normalize(file_path)
  local best_match = nil; local longest_path = 0
  for _, module_meta in pairs(all_modules_map) do
    if module_meta.module_root then
      local normalized_root = unl_path.normalize(module_meta.module_root)
      if normalized_path:find(normalized_root, 1, true) and #normalized_root > longest_path then
        longest_path = #normalized_root; best_match = module_meta
      end
    end
  end
  return best_match
end


-- プラグインのルートディレクトリをキャッシュする変数
local plugin_root_cache = {}

---
-- UEP.nvimやUNL.nvimなど、指定されたプラグインのルートディレクトリを探して返す
-- vim.api.nvim_list_runtime_paths() を使用する
-- @param plugin_name string プラグインのディレクトリ名 (例: "UEP.nvim" or "UNL.nvim")
-- @return string|nil
function M.find_plugin_root(plugin_name)
  if not plugin_name or plugin_name == "" then
    uep_log.get().error("find_plugin_root: plugin_name was nil or empty.")
    return nil
  end

  -- [変更] テーブルからプラグイン名で検索
  if plugin_root_cache[plugin_name] then 
    return plugin_root_cache[plugin_name] 
  end
  
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    -- [/\\] は / または \ にマッチ, $ は末尾
    -- [!] `plugin_name` に含まれる可能性のある `.` をエスケープ
    local search_pattern = "[/\\]" .. plugin_name:gsub("%.", "%.") .. "$"
    if path:match(search_pattern) then
      -- [変更] テーブルにプラグイン名で保存
      plugin_root_cache[plugin_name] = path 
      return path
    end
  end
  
  uep_log.get().error("Could not find plugin root directory named '%s' in runtime paths.", plugin_name)
  return nil
end

---
-- ワーカー-スクリプトへのフルパスを返す汎用関数
-- @param script_name string (例: "parse_headers_worker.lua")
-- @return string|nil
function M.get_worker_script_path(script_name)
  local log = uep_log.get()
  -- [!] "UEP.nvim" をハードコード (ワーカーはUEP.nvimのscripts/にあるため)
  local root = M.find_plugin_root("UEP.nvim") 
  if not root then
    log.error("get_worker_script_path: Cannot find UEP.nvim plugin root.")
    return nil
  end

  local worker_path = fs.joinpath(root, "scripts", script_name)
  if vim.fn.filereadable(worker_path) == 0 then
    log.error("Worker script not found at: %s", worker_path)
    return nil
  end
  
  return worker_path
end

---
-- シンボル定義ファイルを開き、定義行へジャンプする (先行宣言をスキップ)
-- @param target_file_path string 開くファイルのフルパス
-- @param symbol_name string ジャンプ対象のシンボル名 (クラス/構造体/Enum)
function M.open_file_and_jump(target_file_path, symbol_name)
  local log = uep_log.get()
  log.info("Attempting to jump to definition in: %s for symbol: %s", target_file_path, symbol_name)

  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target_file_path))
  if not ok then
    return log.error("Failed to open file '%s': %s", target_file_path, tostring(err))
  end

  local file_content = vim.fn.readfile(target_file_path)
  if vim.v.shell_error ~= 0 then
      log.warn("Could not read file content for jumping: %s", target_file_path)
      vim.fn.cursor(1, 0)
      vim.cmd("normal! zz")
      return
  end

  local line_number = 1
  local found_definition = false

  -- インデントと単語境界に対応したパターン
  local pattern_prefix = [[\.\{-}]] -- インデント(任意文字の最短一致)に対応
  
  local search_pattern_class  = pattern_prefix .. [[class\s\+\(.\{-}_API\s\+\)\?\<]] .. symbol_name .. [[\>]]
  local search_pattern_struct = pattern_prefix .. [[struct\s\+\(.\{-}_API\s\+\)\?\<]] .. symbol_name .. [[\>]]
  local search_pattern_enum   = pattern_prefix .. [[enum\s\+\(class\s\+\)\?\<]] .. symbol_name .. [[\>]]

  for i, line in ipairs(file_content) do
    local class_match  = vim.fn.match(line, search_pattern_class)
    local struct_match = vim.fn.match(line, search_pattern_struct)
    local enum_match   = vim.fn.match(line, search_pattern_enum)

    if class_match >= 0 or struct_match >= 0 or enum_match >= 0 then
      local trimmed_line = line:match("^%s*(.-)%s*$") 
      if trimmed_line:match(";%s*(//.*)?$") or trimmed_line:match(";%s*(/%*.*%*/)?%s*$") then
         log.debug("Skipping potential forward declaration on line %d: %s", i, line)
      else
         line_number = i
         found_definition = true
         log.debug("Definition likely found on line %d: %s", i, line)
         break -- Stop searching
      end
    end
  end

  if not found_definition then
      log.warn("Could not find exact definition line for '%s' in %s. Jumping to first occurrence or line 1.", symbol_name, target_file_path)
      for i, line in ipairs(file_content) do
          local class_match  = vim.fn.match(line, search_pattern_class)
          local struct_match = vim.fn.match(line, search_pattern_struct)
          local enum_match   = vim.fn.match(line, search_pattern_enum)
          if class_match >= 0 or struct_match >= 0 or enum_match >= 0 then
              line_number = i
              break
          end
      end
  end

  vim.fn.cursor(line_number, 0)
  vim.cmd("normal! zz")
end
-- ▲▲▲ [新規追加] ここまで ▲▲▲

return M
