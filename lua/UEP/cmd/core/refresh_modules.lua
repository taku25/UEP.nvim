-- lua/UEP/cmd/core/refresh_modules.lua (API呼び出し修正版)

local class_parser = require("UEP.parser.class")
local uep_config = require("UEP.config")
local module_cache = require("UEP.cache.module") 
local uep_log = require("UEP.logger")
local core_utils = require("UEP.cmd.core.utils")
-- local unl_progress = require("UNL.backend.progress")
local fs = require("vim.fs") -- ★ fs を require

local M = {}

-- (M.create_fd_command は変更なし)
function M.create_fd_command(base_paths, type_flag)
  local conf = uep_config.get()
  local exclude_dirs = conf.excludes_directory
  local fd_cmd = { 
    "fd", 
    "--full-path", 
    "--type", type_flag, 
    "--path-separator", "/",
    "--no-ignore",
    "--hidden"
  }
  for _, dir in ipairs(exclude_dirs) do 
    table.insert(fd_cmd, "--exclude")
    table.insert(fd_cmd, dir) 
  end
  if type_flag == "f" then
    local extensions = conf.include_extensions
    for _, ext in ipairs(extensions) do
      if ext ~= "uproject" and ext ~= "uplugin" then
        table.insert(fd_cmd, "--extension")
        table.insert(fd_cmd, ext)
      end
    end
  end
  for _, path in ipairs(base_paths) do
    table.insert(fd_cmd, "--search-path")
    table.insert(fd_cmd, path)
  end
  return fd_cmd
end


function M.create_module_caches_for(modules_to_refresh_meta, all_modules_meta, progress, game_root, engine_root, on_done)
  local log = uep_log.get()
  local modules_to_refresh_list = vim.tbl_values(modules_to_refresh_meta)
  local total_count = #modules_to_refresh_list

  -- ▼▼▼ 疑似モジュール名を定義 ▼▼▼
  local PSEUDO_MODULES = {
    EngineShaders = { name = "_EngineShaders", root = fs.joinpath(engine_root, "Engine", "Shaders") },
    EngineConfig = { name = "_EngineConfig", root = fs.joinpath(engine_root, "Engine", "Config") },
    -- EngineContent は巨大すぎるので通常は含めない
    GameShaders = { name = "_GameShaders", root = fs.joinpath(game_root, "Shaders") },
    GameConfig = { name = "_GameConfig", root = fs.joinpath(game_root, "Config") },
    GameContent = { name = "_GameContent", root = fs.joinpath(game_root, "Content") },
    -- 他にも必要なら追加 (例: GamePrograms?)
  }
  -- ▲▲▲ ここまで ▲▲▲

  progress:stage_define("module_file_scan", 1)
  progress:stage_update("module_file_scan", 0, ("Scanning files for %d modules (+ pseudo)..."):format(total_count))

  if total_count == 0 then
    -- モジュール更新対象がなくても、疑似モジュールは更新する可能性がある
    log.info("No regular modules need file scanning, but checking pseudo modules.")
    -- ★ ここで return せず、疑似モジュール処理に進む必要があるが、
    -- ★ まずは通常のフローで疑似モジュールが扱えるか確認する
    -- if on_done then on_done(true) end
    -- return
  end

  local top_level_search_paths = { game_root, engine_root }

  if not game_root or not engine_root then
    log.error("game_root or engine_root is nil. Cannot perform file scan.")
    if on_done then on_done(false) end
    return
  end

  local fd_cmd_files = M.create_fd_command(top_level_search_paths, "f")
  local fd_cmd_dirs = M.create_fd_command(top_level_search_paths, "d")

  local all_found_files = {}
  local all_found_dirs = {}
  local files_stderr = {}

  local job_ok, job_id_or_err = pcall(vim.fn.jobstart, fd_cmd_files, {
    stdout_buffered = true, stderr_buffered = true,
    on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_found_files, line) end end end end,
    on_stderr = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(files_stderr, line) end end end end,
    on_exit = function(_, files_code)
      if files_code ~= 0 then
        log.error("fd (files) command failed: %s", table.concat(files_stderr, "\n"))
        if on_done then on_done(false) end; return
      end

      vim.schedule(function()
        local dirs_stderr = {}
        local job2_ok, job2_id_or_err = pcall(vim.fn.jobstart, fd_cmd_dirs, {
          stdout_buffered = true, stderr_buffered = true,
          on_stdout = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_found_dirs, line) end end end end,
          on_stderr = function(_, data) if data then for _, line in ipairs(data) do if line ~= "" then table.insert(dirs_stderr, line) end end end end,
          on_exit = function(_, dirs_code)
            if dirs_code ~= 0 then
              log.error("fd (dirs) command failed: %s", table.concat(dirs_stderr, "\n"))
              if on_done then on_done(false) end; return
            end

            progress:stage_update("module_file_scan", 1, ("File scan complete (%d files, %d dirs). Classifying..."):format(#all_found_files, #all_found_dirs))

            -- STEP 3: 振り分け
            local files_by_module = {}
            local dirs_by_module = {}

            -- ▼▼▼ 疑似モジュール用のバケツも初期化 ▼▼▼
            for _, pseudo in pairs(PSEUDO_MODULES) do
                files_by_module[pseudo.name] = { source={}, config={}, shader={}, programs={}, other={}, content={} } -- content追加
                dirs_by_module[pseudo.name] = { source={}, config={}, shader={}, programs={}, other={}, content={} }
            end
            -- ▲▲▲ ここまで ▲▲▲

            for name, _ in pairs(modules_to_refresh_meta) do
              files_by_module[name] = { source={}, config={}, shader={}, programs={}, other={}, content={} }
              dirs_by_module[name] = { source={}, config={}, shader={}, programs={}, other={}, content={} }
            end

            -- 実際のモジュールリスト（長いパス優先）
            local sorted_modules_to_refresh = vim.deepcopy(modules_to_refresh_list)
            table.sort(sorted_modules_to_refresh, function(a,b) return #a.module_root > #b.module_root end)

            -- ▼▼▼ 振り分けロジック修正 ▼▼▼
            for _, file in ipairs(all_found_files) do
              local assigned = false
              -- 1. まず実際のモジュールに割り当て試行
              for _, mod_meta in ipairs(sorted_modules_to_refresh) do
                if mod_meta.module_root and file:find(mod_meta.module_root, 1, true) then
                  local category = core_utils.categorize_path(file)
                  if category ~= "uproject" and category ~= "uplugin" then
                    if not files_by_module[mod_meta.name][category] then
                      files_by_module[mod_meta.name][category] = {}
                    end
                    table.insert(files_by_module[mod_meta.name][category], file)
                  end
                  assigned = true
                  break -- 最初の（最も深い）一致で終了
                end
              end

              -- 2. どのモジュールにも属さなければ、疑似モジュールに割り当て試行
              if not assigned then
                for _, pseudo in pairs(PSEUDO_MODULES) do
                  if file:find(pseudo.root, 1, true) then
                    local category = core_utils.categorize_path(file)
                    -- 疑似モジュールではカテゴリ分類は単純化しても良いかも
                    if not files_by_module[pseudo.name][category] then
                        files_by_module[pseudo.name][category] = {}
                    end
                    table.insert(files_by_module[pseudo.name][category], file)
                    assigned = true
                    break
                  end
                end
              end
              -- if not assigned then log.trace("File not assigned: %s", file) end -- どのモジュールにも属さないファイル
            end
            -- (ディレクトリも同様に振り分け)
            for _, dir in ipairs(all_found_dirs) do
                local assigned = false
                for _, mod_meta in ipairs(sorted_modules_to_refresh) do
                    if mod_meta.module_root and dir:find(mod_meta.module_root, 1, true) then
                        local category = core_utils.categorize_path(dir)
                        if category ~= "uproject" and category ~= "uplugin" then
                            if not dirs_by_module[mod_meta.name][category] then dirs_by_module[mod_meta.name][category] = {} end
                            table.insert(dirs_by_module[mod_meta.name][category], dir)
                        end
                        assigned = true; break
                    end
                end
                if not assigned then
                    for _, pseudo in pairs(PSEUDO_MODULES) do
                        if dir:find(pseudo.root, 1, true) then
                            local category = core_utils.categorize_path(dir)
                            if not dirs_by_module[pseudo.name][category] then dirs_by_module[pseudo.name][category] = {} end
                            table.insert(dirs_by_module[pseudo.name][category], dir)
                            assigned = true; break
                        end
                    end
                end
            end
            -- ▲▲▲ 振り分けロジック修正ここまで ▲▲▲

            -- (STEP 4: クラス解析準備 ... 変更なし)
            progress:stage_define("header_analysis", #all_found_files)
            local all_existing_header_details = {}
            for mod_name, mod_meta in pairs(all_modules_meta) do
                if not modules_to_refresh_meta[mod_name] then
                  local existing_cache = module_cache.load(mod_meta)
                  if existing_cache and existing_cache.header_details then
                      for file_path, details in pairs(existing_cache.header_details) do
                          all_existing_header_details[file_path] = details
                      end
                  end
                end
            end
            -- ★ 疑似モジュールのヘッダー詳細もロードする (必要であれば)
            for _, pseudo in pairs(PSEUDO_MODULES) do
                local pseudo_meta = { name=pseudo.name, module_root=pseudo.root } -- cache.load 用のダミーmeta
                local existing_cache = module_cache.load(pseudo_meta)
                if existing_cache and existing_cache.header_details then
                    for file_path, details in pairs(existing_cache.header_details) do
                        all_existing_header_details[file_path] = details
                    end
                end
            end

            local headers_to_parse = {}
            for _, file in ipairs(all_found_files) do
              if file:match("%.h$") and not file:find("NoExportTypes.h", 1, true) then
                table.insert(headers_to_parse, file)
              end
            end
            log.info("Identified %d header files to parse out of %d total files found.", #headers_to_parse, #all_found_files)

            -- (STEP 5: クラス解析実行 ... 変更なし)
            class_parser.parse_headers_async(all_existing_header_details, headers_to_parse, progress, function(ok, header_details_by_file)

              if not ok then
                log.error("Header parsing failed, aborting module cache save.")
                if on_done then on_done(false) end
                return
              end

              -- ▼▼▼ STEP 6: 保存 (疑似モジュールも保存) ▼▼▼
              -- ★ 保存対象数を疑似モジュール分も考慮 (正確性は欠くが目安として)
              progress:stage_define("module_cache_save", total_count + vim.tbl_count(PSEUDO_MODULES))
              local saved_count = 0

              -- 6a: 実際のモジュールを保存
              for module_name, module_meta in pairs(modules_to_refresh_meta) do
                saved_count = saved_count + 1
                progress:stage_update("module_cache_save", saved_count, ("Saving: %s [%d/%d]"):format(module_name, saved_count, total_count))
                local module_files_data = files_by_module[module_name]
                local module_dirs_data = dirs_by_module[module_name]
                if module_files_data and module_dirs_data then
                  local module_header_details = {}
                  if header_details_by_file then
                    if module_files_data.source then
                      for _, file in ipairs(module_files_data.source) do
                        if header_details_by_file[file] then module_header_details[file] = header_details_by_file[file] end
                      end
                    end
                  end
                  local data_to_save = { files = module_files_data, directories = module_dirs_data, header_details = module_header_details }
                  module_cache.save(module_meta, data_to_save)
                else
                  module_cache.save(module_meta, { files = {}, directories = {}, header_details = {} })
                end
              end

              -- 6b: 疑似モジュールを保存
              for _, pseudo in pairs(PSEUDO_MODULES) do
                 saved_count = saved_count + 1
                 progress:stage_update("module_cache_save", saved_count, ("Saving: %s [%d/%d]"):format(pseudo.name, saved_count, total_count + vim.tbl_count(PSEUDO_MODULES)))
                 local pseudo_files_data = files_by_module[pseudo.name]
                 local pseudo_dirs_data = dirs_by_module[pseudo.name]
                 if pseudo_files_data and pseudo_dirs_data then
                     local pseudo_header_details = {}
                     -- ★ 疑似モジュール内のヘッダーも解析結果を保存する
                     if header_details_by_file then
                        -- カテゴリを限定せず、この疑似モジュールに属する全ファイルを見る
                        for category, files in pairs(pseudo_files_data) do
                           for _, file in ipairs(files) do
                              if header_details_by_file[file] then pseudo_header_details[file] = header_details_by_file[file] end
                           end
                        end
                     end
                     local data_to_save = { files = pseudo_files_data, directories = pseudo_dirs_data, header_details = pseudo_header_details }
                     -- ★ cache.save に渡すためのダミーmeta を作成
                     local pseudo_meta = { name = pseudo.name, module_root = pseudo.root }
                     module_cache.save(pseudo_meta, data_to_save)
                 end
              end
              -- ▲▲▲ 保存ロジック修正ここまで ▲▲▲

              progress:stage_update("module_cache_save", saved_count, "All module caches saved.")
              if on_done then on_done(true) end
            end) -- class_parser.parse_headers_async の終わり
          end, -- job2 on_exit の終わり
        }) -- job2 pcall(jobstart) の終わり
        if not job2_ok then log.error("Failed to start fd (dirs) job: %s", tostring(job2_id_or_err)); if on_done then on_done(false) end end
      end) -- vim.schedule の終わり
    end, -- job1 on_exit の終わり
  }) -- job1 pcall(jobstart) の終わり
  if not job_ok then log.error("Failed to start fd (files) job: %s", tostring(job_id_or_err)); if on_done then on_done(false) end end
end -- M.create_module_caches_for の終わり

return M
