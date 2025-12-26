-- lua/UEP/parser/class.lua (ハッシュ計算をワーカーに移譲)

local uep_logger_module = require("UEP.logger")
local fs = require("vim.fs")
local core_utils = require("UEP.cmd.core.utils")

local M = {}

-- [削除] get_file_hash 関数はメインスレッドでは不要になったため削除

----------------------------------------------------------------------
-- 非同期実行関数 (Job/Worker 版)
----------------------------------------------------------------------

-- [既存] get_cpu_count
local function get_cpu_count()
    local cpus = vim.loop.cpu_info()
    return (cpus and #cpus > 0) and #cpus or 4
end


function M.parse_headers_async(existing_header_details, header_files, progress, on_complete)
  local uep_log = uep_logger_module.get()
  local start_time = os.clock()

  -- new_details は最終結果を格納する
  local new_details = {} 
  existing_header_details = existing_header_details or {}
  
  -- files_to_parse はワーカーに送るファイル情報のリスト
  local files_to_parse = {} 
  -- [削除] mtimes_map, hashes_map は不要

  local total_header_file = #header_files
  uep_log.debug("parse_headers_async (Worker Mode): Starting check for %d files.", total_header_file)
  progress:stage_define("header_analysis_detail", total_header_file)

  -- ▼▼▼ [修正] STEP 1: キャッシュ検証 (mtime のみ) ▼▼▼
  for i, file_path in ipairs(header_files) do
    if i % 500 == 0 then
        progress:stage_update("header_analysis_detail", i, ("Checking mtime: %s (%d/%d)..."):format(vim.fn.fnamemodify(file_path, ":t"), i, total_header_file))
    end
    
    local stat = vim.loop.fs_stat(file_path)
    
    if not stat then
        uep_log.trace("File not readable (stat failed), skipping: %s", file_path)
        goto continue_loop
    end
    
    local current_mtime = stat.mtime.sec
    local existing_entry = existing_header_details[file_path]

    -- 1. mtime が同じなら、即時OK (ワーカーに送らない)
    if existing_entry and existing_entry.mtime and existing_entry.mtime == current_mtime then
      new_details[file_path] = existing_entry
    else
      -- 2. mtime が違う (または新規) なら、ワーカーにチェックを依頼
      -- [!] ハッシュ計算はせず、ペイロードに追加
      table.insert(files_to_parse, {
          path = file_path,
          mtime = current_mtime,
          old_hash = (existing_entry and existing_entry.file_hash) or nil
      })
    end
    ::continue_loop::
  end
  -- ▲▲▲ STEP 1 修正完了 ▲▲▲
  
  local files_to_parse_count = #files_to_parse
  local files_from_cache_count = total_header_file - files_to_parse_count
  
  uep_log.info("mtime check complete. %d files from cache, %d files require hash check/parse by worker.", files_from_cache_count, files_to_parse_count)

  -- STEP 2: パース対象がなければ、ここで終了
  if files_to_parse_count == 0 then
    progress:stage_update("header_analysis_detail", total_header_file, "All headers up-to-date.")
    on_complete(true, new_details)
    return
  end

  -- STEP 3: ワーカーの準備
  local worker_script_path = core_utils.get_worker_script_path("parse_headers_worker.lua")
  if not worker_script_path then
    uep_log.error("Could not find worker script. Aborting parallel parse.")
    return on_complete(false, "Worker script path not found.")
  end
  
  local nvim_cmd = {
      vim.v.progpath,
      "--headless",
      "--clean",
      "-c", ("luafile %s"):format(worker_script_path)
  }
  
  local max_workers = math.min(get_cpu_count(), 16)
  local total_jobs = math.min(max_workers, files_to_parse_count)
  
  local chunks = {}
  for i = 1, total_jobs do chunks[i] = {} end
  -- [!] files_to_parse は {path=..., mtime=..., old_hash=...} のテーブル
  for i, file_data in ipairs(files_to_parse) do
      table.insert(chunks[(i % total_jobs) + 1], file_data)
  end

  uep_log.info("Starting %d parallel workers to process %d files...", total_jobs, files_to_parse_count)
  
  local jobs_completed = 0
  -- [!] merged_worker_results は「パースされた」結果のみを保持
  local merged_worker_results = {} 
  local job_stderr_logs = {}
  local all_jobs_started = true

  -- STEP 4: ジョブの起動
  for i = 1, total_jobs do
    local chunk_files_data = chunks[i] -- これは {path=...} のリスト
    
    if #chunk_files_data == 0 then
        uep_log.warn("Worker job #%d was assigned 0 files. Skipping.", i)
        jobs_completed = jobs_completed + 1
    else
        -- [!] ペイロードはファイルオブジェクトのリストそのもの
        local payload_json = vim.json.encode(chunk_files_data)
        
        local job_stderr = {}
        
        local job_id = vim.fn.jobstart(nvim_cmd, {
          rpc = false,
          stdout_buffered = true,
          stderr_buffered = true,
          
          on_stdout = function(job_id_cb, data, _)
            if not data then return end
            for _, line in ipairs(data) do
                if line and line ~= "" then
                    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
                    if trimmed ~= "" then
                      local ok_line, worker_result = pcall(vim.json.decode, trimmed)
                      if ok_line and type(worker_result) == "table" and worker_result.path then
                        -- ▼▼▼ ワーカーからの結果を処理 ▼▼▼
                        local res = worker_result
                        
                        if res.status == "cache_hit" then
                          if existing_header_details[res.path] then
                              new_details[res.path] = existing_header_details[res.path]
                              new_details[res.path].mtime = res.mtime
                          else
                              uep_log.warn("Worker reported cache hit, but no existing data found for %s", res.path)
                          end
                          
                        elseif res.status == "parsed" then
                          merged_worker_results[res.path] = {
                              classes = res.data.classes,
                              file_hash = res.data.new_hash,
                              mtime = res.mtime
                          }
                        end
                        -- ▲▲▲ 処理完了 ▲▲▲
                      else
                          -- noisy空行は無視、内容があるのに失敗した場合のみwarn
                          if trimmed ~= "" then
                            uep_log.warn("Worker (job_id %s): Failed to decode JSON line: %s", job_id_cb, trimmed)
                          end
                      end
                    end
                end
            end
          end,

          on_stderr = function(_, data, _)
            if data then vim.list_extend(job_stderr, data) end
          end,

          on_exit = function(id, code, _)
            uep_log.debug("Worker job %d finished with code %d.", id, code)
            
            local stderr_output = table.concat(job_stderr, "\n")
            
            if code ~= 0 then
              table.insert(job_stderr_logs, ("Worker %d failed (code %d):\n%s"):format(id, code, stderr_output))
            else
              if stderr_output ~= "" then
                 uep_log.warn("Worker %d exited with code 0 but reported to stderr:\n%s", id, stderr_output)
              end
            end
            
            jobs_completed = jobs_completed + 1
            
            local processed_so_far = files_from_cache_count + math.floor(files_to_parse_count * (jobs_completed / total_jobs))
            progress:stage_update("header_analysis_detail", processed_so_far, ("Processing: %d/%d files... (%d/%d workers)"):format(processed_so_far, total_header_file, jobs_completed, total_jobs))

            -- STEP 5: 全ジョブ完了時の処理
            if jobs_completed == total_jobs then
              local end_job_time = os.clock()
              uep_log.info("All %d workers finished in %.4f seconds.", total_jobs, end_job_time - start_time)
              
              if #job_stderr_logs > 0 then
                uep_log.error("Some workers failed:\n%s", table.concat(job_stderr_logs, "\n\n"))
              end
              
              local worker_results_count = vim.tbl_count(merged_worker_results)
              uep_log.info("Total results from workers (parsed): %d", worker_results_count)

              -- [!] `new_details` には "cache_hit" の結果が既に入っている
              -- [!] ここで "parsed" の結果をマージする
              uep_log.debug("Manually merging %d parsed worker results into new_details map...", worker_results_count)
              for file_path, data in pairs(merged_worker_results) do
                  new_details[file_path] = data
              end
              
              local final_total_count = vim.tbl_count(new_details)
              uep_log.info("Header parsing complete. Total symbols (files in map): %d", final_total_count) 
              progress:stage_update("header_analysis_detail", total_header_file, "Header analysis complete.")
              
              on_complete(true, new_details)
            end
          end,
        })
        
        if job_id <= 0 then
            uep_log.error("Failed to start worker job #%d.", i)
            jobs_completed = jobs_completed + 1
            all_jobs_started = false
        else
            uep_log.debug("Started worker job %d (PID: %s) for %d files.", i, vim.fn.jobpid(job_id), #chunk_files_data)
            vim.fn.chansend(job_id, payload_json)
            vim.fn.chanclose(job_id, "stdin")
        end
    end
  end

  if not all_jobs_started and jobs_completed == total_jobs then
      uep_log.error("Failed to start ANY worker jobs.")
      on_complete(false, "Failed to start any worker jobs.")
  end
end


return M
