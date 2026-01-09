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
  
  local total_header_file = #header_files
  uep_log.debug("parse_headers_async (Worker Mode): Starting check for %d files.", total_header_file)
  progress:stage_define("header_analysis_detail", total_header_file)

  local BATCH_SIZE = 1000
  local current_idx = 1
  
  -- 前方宣言
  local finish_mtime_check
  local trigger_worker_logic

  -- バッチ処理関数
  local function process_mtime_batch()
      local batch_end = math.min(current_idx + BATCH_SIZE - 1, total_header_file)
      
      for i = current_idx, batch_end do
          local file_path = header_files[i]
          
          if i % 1000 == 0 then -- UI更新頻度を下げる
             progress:stage_update("header_analysis_detail", i, ("Checking mtime: %s (%d/%d)..."):format(vim.fn.fnamemodify(file_path, ":t"), i, total_header_file))
          end
        
          local stat = vim.loop.fs_stat(file_path)
          
          if stat then
              local current_mtime = stat.mtime.sec
              local existing_entry = existing_header_details[file_path]
      
              -- mtime が同じなら、即時OK
              if existing_entry and existing_entry.mtime and existing_entry.mtime == current_mtime then
                -- [変更] Cache Hit の場合は new_details に追加しない (DB更新スキップのため)
                -- new_details[file_path] = existing_entry
              else
                table.insert(files_to_parse, {
                    path = file_path,
                    mtime = current_mtime,
                    old_hash = (existing_entry and existing_entry.file_hash) or nil
                })
              end
          else
             uep_log.trace("File not readable (stat failed), skipping: %s", file_path)
          end
      end
      
      current_idx = batch_end + 1
      if current_idx <= total_header_file then
          vim.schedule(process_mtime_batch)
      else
          finish_mtime_check()
      end
  end

  finish_mtime_check = function()
      local files_to_parse_count = #files_to_parse
      local files_from_cache_count = total_header_file - files_to_parse_count
      
      uep_log.info("mtime check complete. %d files from cache, %d files require hash check/parse by worker.", files_from_cache_count, files_to_parse_count)
    
      if files_to_parse_count == 0 then
        progress:stage_update("header_analysis_detail", total_header_file, "All headers up-to-date.")
        on_complete(true, new_details)
        return
      end
    
      local worker_script_path = core_utils.get_worker_script_path("parse_headers_worker.lua")
      if not worker_script_path then
        uep_log.error("Could not find worker script. Aborting parallel parse.")
        return on_complete(false, "Worker script path not found.")
      end
    
      local parser_paths = vim.api.nvim_get_runtime_file("parser/cpp.*", true)
      local rtp_list = {}
      for _, p in ipairs(parser_paths) do
          local parser_dir = vim.fn.fnamemodify(p, ":h")
          local root_dir = vim.fn.fnamemodify(parser_dir, ":h")
          table.insert(rtp_list, root_dir)
      end
      local ts_rtp_env = table.concat(rtp_list, ",")
      
      trigger_worker_logic(worker_script_path, ts_rtp_env, files_to_parse_count, files_from_cache_count)
  end

  trigger_worker_logic = function(worker_script_path, ts_rtp_env, files_to_parse_count, files_from_cache_count)
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
      for i, file_data in ipairs(files_to_parse) do
          table.insert(chunks[(i % total_jobs) + 1], file_data)
      end
    
      uep_log.info("Starting %d parallel workers to process %d files...", total_jobs, files_to_parse_count)
      
      local jobs_completed = 0
      local merged_worker_results = {} 
      local job_stderr_logs = {}
      local all_jobs_started = true
    
      for i = 1, total_jobs do
        -- jobstart のコールバック内で使用変数を正しくキャプチャするように注意
        -- ここでは i や chunk_files_data はループ内でローカルなのでOK
        local chunk_files_data = chunks[i] 
        
        if #chunk_files_data == 0 then
            uep_log.warn("Worker job #%d was assigned 0 files. Skipping.", i)
            jobs_completed = jobs_completed + 1
        else
            local payload_json = vim.json.encode(chunk_files_data)
            local job_stderr = {}
            
            local job_id = vim.fn.jobstart(nvim_cmd, {
              env = { ["UEP_TS_RTP"] = ts_rtp_env },
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
                            local res = worker_result
                            if res.status == "cache_hit" then
                                -- [変更] キャッシュヒット時は、new_details に追加しない 
                                -- (writer側で、new_detailsにない=変更なし=更新不要と判断させる)
                                -- uep_log.trace("Cache hit for %s", res.path)
                            elseif res.status == "parsed" then
                              merged_worker_results[res.path] = {
                                  classes = res.data.classes,
                                  file_hash = res.data.new_hash,
                                  mtime = res.mtime
                              }
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
                -- uep_log.debug("Worker job %d finished with code %d.", id, code)
                local stderr_output = table.concat(job_stderr, "\n")
                if code ~= 0 then
                  table.insert(job_stderr_logs, ("Worker %d failed (code %d):\n%s"):format(id, code, stderr_output))
                end
                
                jobs_completed = jobs_completed + 1
                
                local processed_so_far = files_from_cache_count + math.floor(files_to_parse_count * (jobs_completed / total_jobs))
                progress:stage_update("header_analysis_detail", processed_so_far, ("Processing... (%d/%d workers)"):format(jobs_completed, total_jobs))
    
                if jobs_completed == total_jobs then
                  local end_job_time = os.clock()
                  uep_log.info("All %d workers finished in %.4f seconds.", total_jobs, end_job_time - start_time)
                  if #job_stderr_logs > 0 then uep_log.error("Some workers failed:\n%s", table.concat(job_stderr_logs, "\n\n")) end
                  
                  local worker_results_count = vim.tbl_count(merged_worker_results)
                  uep_log.debug("Merging %d results...", worker_results_count)
                  for file_path, data in pairs(merged_worker_results) do
                      new_details[file_path] = data
                  end
                  
                  on_complete(true, new_details)
                end
              end,
            })
            
            if job_id <= 0 then
                jobs_completed = jobs_completed + 1
                all_jobs_started = false
            else
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

  -- 処理開始
  vim.schedule(process_mtime_batch)
end


return M
