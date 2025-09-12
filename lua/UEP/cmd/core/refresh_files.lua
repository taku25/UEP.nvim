-- lua/UEP/cmd/core/refresh_files.lua (モジュール中心設計・最終完成版)
local class_parser = require("UEP.parser.class")
local uep_config = require("UEP.config")
local files_disk_cache = require("UEP.cache.files")
local uep_log = require("UEP.logger")
local project_cache = require("UEP.cache.project")
local unl_progress = require("UNL.backend.progress") -- ★★★ progressをrequire ★★★
local M = {}

-------------------------------------------------
-- ヘルパー関数 (変更なし)
-------------------------------------------------
local function create_fd_command_for_files(search_paths)
  local conf = uep_config.get()
  local extensions = conf.files_extensions or { "cpp", "h", "hpp", "inl", "ini", "cs" }
  local full_path_regex = ".*[\\\\/](Source|Config|Plugins)[\\\\/].*\\.(" .. table.concat(extensions, "|") .. ")$"
  local excludes = { "Intermediate", "Binaries", "Saved", ".git", ".vs" }
  local fd_cmd = { "fd", "--regex", full_path_regex, "--full-path", "--type", "f", "--path-separator", "/", "--absolute-path" }
  for _, dir in ipairs(excludes) do table.insert(fd_cmd, "--exclude"); table.insert(fd_cmd, dir) end
  table.insert(fd_cmd, ".")
  if search_paths and type(search_paths) == "table" then
    vim.list_extend(fd_cmd, search_paths)
  end
  return fd_cmd
end

local function create_fd_command_for_dirs(search_paths)
  local full_path_regex = ".*[\\\\/](Source|Config|Plugins)[\\\\/].*"
  local excludes = { "Intermediate", "Binaries", "Saved", ".git", ".vs" }
  local fd_cmd = { "fd", "--regex", full_path_regex, "--full-path", "--type", "d", "--path-separator", "/", "--absolute-path" }
  for _, dir in ipairs(excludes) do table.insert(fd_cmd, "--exclude"); table.insert(fd_cmd, dir) end
  if search_paths and type(search_paths) == "table" then
    vim.list_extend(fd_cmd, search_paths)
  end
  return fd_cmd
end

-------------------------------------------------
-- 公開API
-------------------------------------------------

-- ファイル、ディレクトリ、ヘッダー情報を含む完全なキャッシュを作成する。
-- 責務を完全に移譲された、最終完成版。
-- @param scope "Game" | "Engine"
-- @param project_data table
-- @param engine_data table | nil
-- @param progress table
-- @param on_all_done fun(ok: boolean)
function M.create_cache(scope, project_data, engine_data, progress, on_all_done)
  progress:stage_define("create_file_cache", 1)
  progress:stage_update("create_file_cache", 0, "Scanning files & dirs for " .. scope .. "...")

  local search_path = project_data.root
  local fd_cmd_files = create_fd_command_for_files({ search_path })
  local fd_cmd_dirs = create_fd_command_for_dirs({ search_path })
  local found_files = {}
  local found_dirs = {}

  -- STEP 1: ファイルを非同期で検索
  vim.fn.jobstart(fd_cmd_files, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(found_files, line) end end end end,
    on_exit = function(_, files_code)
      if files_code ~= 0 then if on_all_done then on_all_done(false) end; return end
      
      -- STEP 2: ディレクトリを非同期で検索 (vim.scheduleで安全に実行)
      vim.schedule(function()
        vim.fn.jobstart(fd_cmd_dirs, {
          stdout_buffered = true,
          on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(found_dirs, line) end end end end,
          on_exit = function(_, dirs_code)
            if dirs_code ~= 0 then if on_all_done then on_all_done(false) end; return end

            -- STEP 3: スキャン完了後、キャッシュ構造を構築
            local all_modules_meta = vim.tbl_deep_extend("force", {}, engine_data and engine_data.modules or {}, project_data.modules)
            local sorted_modules = {}
            for name, meta in pairs(all_modules_meta) do
              if meta.module_root then
                table.insert(sorted_modules, { name = name, root = meta.module_root .. "/" })
              end
            end
            table.sort(sorted_modules, function(a, b) return #a.root > #b.root end)

            local modules_data = {}
            -- project_data (Gameスコープ) に含まれるモジュールだけを初期化の対象とする
            for name, _ in pairs(project_data.modules) do
              modules_data[name] = { files = {}, directories = {}, header_details = {} }
            end

            local function find_owner(path)
              for _, meta in ipairs(sorted_modules) do
                if path:find(meta.root, 1, true) then return meta.name end
              end
              return nil
            end
            for _, file_path in ipairs(found_files) do
              local owner = find_owner(file_path)
              if owner and modules_data[owner] then table.insert(modules_data[owner].files, file_path) end
            end
            for _, dir_path in ipairs(found_dirs) do
              local owner = find_owner(dir_path)
              if owner and modules_data[owner] then table.insert(modules_data[owner].directories, dir_path) end
            end
            
            -- STEP 4: ヘッダー解析官に、ヘッダー解析を命令
            local headers_to_parse = {}
            for _, file_path in ipairs(found_files) do
                if file_path:match("%.h$") then table.insert(headers_to_parse, file_path) end
            end
            
            class_parser.parse_headers_async(project_data.root, headers_to_parse, progress, function(ok, header_details_by_file)
                if ok and header_details_by_file then
                    -- 解析結果を、各モジュールの header_details に振り分ける
                    for file_path, details in pairs(header_details_by_file) do
                        local owner_module = find_owner(file_path)
                        if owner_module and modules_data[owner_module] then
                            modules_data[owner_module].header_details[file_path] = details
                        end
                    end
                end

                -- STEP 5: 全ての情報を元に、最終的なキャッシュを保存
                local cache_to_save = {
                    category = scope,
                    generation = project_data.generation,
                    owner_project_root = project_data.root,
                    modules_data = modules_data,
                }
                files_disk_cache.save(project_data.root, cache_to_save)
                progress:stage_update("create_file_cache", 1, "File cache for " .. scope .. " created.")
                if on_all_done then on_all_done(true) end
            end)
          end
        })
      end)
    end
  })
end


---
-- 単一モジュールのキャッシュを、新しい「モジュール中心」構造で更新する
---
-- 単一モジュールのキャッシュを、ファイル、ディレクトリ、ヘッダー情報を含めて完全に更新する。
-- プログレスバー表示にも対応した、最終完成版。
-- @param module_name string 更新したいモジュール名
-- @param on_complete function(ok, passthrough_payload) 完了時に呼ばれるコールバック
function M.update_single_module_cache(module_name, on_complete, passthrough_payload)
  -- 1. 必要なデータをロード (変更なし)
  local game_data = project_cache.load(vim.loop.cwd())
  if not game_data then if on_complete then on_complete(false, passthrough_payload) end; return end
  local engine_data = game_data.link_engine_cache_root and project_cache.load(game_data.link_engine_cache_root) or nil
  local all_modules = vim.tbl_deep_extend("force", {}, engine_data and engine_data.modules or {}, game_data.modules or {})
  local target_module = all_modules[module_name]
  if not (target_module and target_module.module_root) then
    if on_complete then on_complete(false, passthrough_payload) end
    return
  end
  
  -- ★★★ 2. 軽量更新用のプログレスバーを準備 ★★★
  local conf = uep_config.get()
  local progress, _ = unl_progress.create_for_refresh(conf, { 
    title = "UCM: Updating module...", 
    client_name = "UCM" 
  })
  progress:open()
  progress:stage_define("scan_files", 0.4) -- 重み付け
  progress:stage_define("scan_dirs", 0.2)
  progress:stage_define("parse_headers", 0.4)

  -- 3. fdコマンドを構築
  local fd_cmd_files = create_fd_command_for_files({ target_module.module_root })
  local fd_cmd_dirs = create_fd_command_for_dirs({ target_module.module_root })
  local found_files = {}
  local found_dirs = {}

  -- STEP A: ファイルを検索
  progress:stage_update("scan_files", 0, "Scanning files...")
  vim.fn.jobstart(fd_cmd_files, {
    stdout_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(found_files, line) end end end end,
    on_exit = function(_, files_code)
      if files_code ~= 0 then progress:finish(false); if on_complete then on_complete(false, passthrough_payload) end; return end
      progress:stage_update("scan_files", 1, "Found " .. #found_files .. " files.")
      
      -- STEP B: ディレクトリを検索
      vim.schedule(function()
        progress:stage_update("scan_dirs", 0, "Scanning directories...")
        vim.fn.jobstart(fd_cmd_dirs, {
          stdout_buffered = true,
          on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(found_dirs, line) end end end end,
          on_exit = function(_, dirs_code)
            if dirs_code ~= 0 then progress:finish(false); if on_complete then on_complete(false, passthrough_payload) end; return end
            progress:stage_update("scan_dirs", 1, "Found " .. #found_dirs .. " directories.")

            -- STEP C: ヘッダーを解析
            local target_project_data = (game_data.modules and game_data.modules[module_name]) and game_data or engine_data
            if not target_project_data then progress:finish(false); if on_complete then on_complete(false, passthrough_payload) end; return end
            
            local headers_to_parse = {}
            for _, file_path in ipairs(found_files) do
              if file_path:match("%.h$") then table.insert(headers_to_parse, file_path) end
            end
            
            -- ★ progressオブジェクトをヘッダーパーサーに渡す
            class_parser.parse_headers_async(target_project_data.root, headers_to_parse, progress, function(ok, header_details)
              header_details = ok and header_details or {}

              -- STEP D: 全ての情報を元に、キャッシュをアトミックに更新
              local full_disk_cache = files_disk_cache.load(target_project_data.root) or { modules_data = {} }
              
              full_disk_cache.modules_data = full_disk_cache.modules_data or {}
              
              full_disk_cache.modules_data[module_name] = {
                files = found_files,
                directories = found_dirs,
                header_details = header_details,
              }
              full_disk_cache.generation = target_project_data.generation
              files_disk_cache.save(target_project_data.root, full_disk_cache)
              
              progress:finish(true)
              uep_log.get().info("Lightweight full module cache update for '%s' complete.", module_name)
              if on_complete then on_complete(true, passthrough_payload) end
            end)
          end
        })
      end)
    end
  })
end

return M
