-- lua/UEP/parser/class.lua (tbl_deep_extend を for ループに置換)

local uep_logger_module = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

----------------------------------------------------------------------
-- 解析関数 (変更なし)
----------------------------------------------------------------------

local MAX_HASH_FILE_SIZE = 5 * 1024 * 1024 -- 5MB limit

local function get_file_hash(file_path, file_size)
  local log = uep_logger_module.get()

  if file_size > MAX_HASH_FILE_SIZE then
      log.trace("get_file_hash: File %s is larger than %dMB. Skipping hash, forcing re-parse.", vim.fn.fnamemodify(file_path, ":t"), MAX_HASH_FILE_SIZE / 1024 / 1024)
      return nil
  end

  if file_size > (1024 * 1024) then
    log.debug("get_file_hash: Hashing file > 1MB in main thread: %s (Size: %.2f MB)", vim.fn.fnamemodify(file_path, ":t"), file_size / 1024 / 1024)
  end

  local read_ok, lines = pcall(vim.fn.readfile, file_path)
  if not read_ok or not lines then
    log.warn("get_file_hash: Could not read file: %s", file_path)
    return nil
  end
  
  local content = table.concat(lines, "\n")
  return vim.fn.sha256(content)
end

----------------------------------------------------------------------
-- 非同期実行関数 (Job/Worker 版)
----------------------------------------------------------------------

-- (get_worker_script_path, get_cpu_count は変更なし)
local function get_worker_script_path()
    local log = uep_logger_module.get()
    local this_file_path = debug.getinfo(1, "S").source
    if not this_file_path or this_file_path:sub(1, 1) ~= "@" then
        log.error("Could not determine worker script path from debug info.")
        return nil
    end
    this_file_path = this_file_path:sub(2)
    local plugin_root = this_file_path:match("(.+)[/\\]lua[/\\]UEP[/\\]parser[/\\]class.lua$")
    if not plugin_root then
        log.error("Could not deduce plugin root from path: %s", this_file_path)
        return nil
    end
    local worker_path = fs.joinpath(plugin_root, "scripts", "parse_headers_worker.lua")
    if vim.fn.filereadable(worker_path) == 0 then
        log.error("Worker script not found at: %s (Deduced Root: %s)", worker_path, plugin_root)
        return nil
    end
    return worker_path
end
local function get_cpu_count()
    local cpus = vim.loop.cpu_info()
    return (cpus and #cpus > 0) and #cpus or 4
end


function M.parse_headers_async(existing_header_details, header_files, progress, on_complete)
  local uep_log = uep_logger_module.get()
  local start_time = os.clock()

  local new_details = {} 
  existing_header_details = existing_header_details or {}
  
  local files_to_parse = {} 
  local mtimes_map = {}
  local hashes_map = {}

  local total_header_file = #header_files
  uep_log.debug("parse_headers_async (Worker Mode): Starting check for %d files.", total_header_file)
  progress:stage_define("header_analysis_detail", total_header_file)

  -- STEP 1: キャッシュ検証 (変更なし)
  for i, file_path in ipairs(header_files) do
    if i % 500 == 0 then
        progress:stage_update("header_analysis_detail", i, ("Checking cache: %s (%d/%d)..."):format(vim.fn.fnamemodify(file_path, ":t"), i, total_header_file))
    end
    
    local stat = vim.loop.fs_stat(file_path)
    
    if not stat then
        uep_log.trace("File not readable (stat failed), skipping: %s", file_path)
        goto continue_loop
    end
    
    local file_size = stat.size
    local current_mtime = stat.mtime.sec

    local existing_entry = existing_header_details[file_path]

    if existing_entry and existing_entry.mtime and existing_entry.mtime == current_mtime then
      new_details[file_path] = existing_entry
    else
      local current_hash = get_file_hash(file_path, file_size) 
      
      if existing_entry and existing_entry.file_hash and current_hash and existing_entry.file_hash == current_hash then
        new_details[file_path] = existing_entry
        new_details[file_path].mtime = current_mtime
      else
        table.insert(files_to_parse, file_path)
        mtimes_map[file_path] = current_mtime
        hashes_map[file_path] = current_hash
      end
    end
    ::continue_loop::
  end
  
  local files_to_parse_count = #files_to_parse
  local files_from_cache_count = total_header_file - files_to_parse_count
  
  uep_log.info("Cache check complete. %d files from cache, %d files require parsing.", files_from_cache_count, files_to_parse_count)

  -- STEP 2: パース対象がなければ、ここで終了 (変更なし)
  if files_to_parse_count == 0 then
    progress:stage_update("header_analysis_detail", total_header_file, "All headers up-to-date.")
    on_complete(true, new_details)
    return
  end

  -- STEP 3: ワーカーの準備 (変更なし)
  local worker_script_path = get_worker_script_path()
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
  for i, file_path in ipairs(files_to_parse) do
      table.insert(chunks[(i % total_jobs) + 1], file_path)
  end

  uep_log.info("Starting %d parallel workers to parse %d files...", total_jobs, files_to_parse_count)
  
  local jobs_completed = 0
  local merged_worker_results = {}
  local job_stderr_logs = {}
  local all_jobs_started = true

  -- STEP 4: ジョブの起動 (on_stdout は変更なし)
  for i = 1, total_jobs do
    local chunk_files = chunks[i]
    
    if #chunk_files == 0 then
        uep_log.warn("Worker job #%d was assigned 0 files. Skipping.", i)
        jobs_completed = jobs_completed + 1
    else
        local payload = {
          files = chunk_files,
          mtimes = mtimes_map,
        }
        local payload_json = vim.json.encode(payload)
        
        local job_stderr = {}
        
        local job_id = vim.fn.jobstart(nvim_cmd, {
          rpc = false,
          
          on_stdout = function(job_id_cb, data, _)
            if not data then return end
            for _, line in ipairs(data) do
                if line and line ~= "" then
                    local ok_line, worker_result = pcall(vim.json.decode, line)
                    if ok_line and type(worker_result) == "table" then
                        for file_path, result_data in pairs(worker_result) do
                            local hash_to_save = hashes_map[file_path]
                            local mtime_to_save = mtimes_map[file_path]
                            
                            merged_worker_results[file_path] = {
                                classes = result_data.classes,
                                file_hash = hash_to_save,
                                mtime = mtime_to_save
                            }
                        end
                    else
                        uep_log.warn("Worker (job_id %s): Failed to decode JSON line: %s", job_id_cb, line)
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
            progress:stage_update("header_analysis_detail", processed_so_far, ("Parsing: %d/%d files... (%d/%d workers)"):format(processed_so_far, total_header_file, jobs_completed, total_jobs))

            -- ▼▼▼ STEP 5: 修正箇所 (tbl_deep_extend -> for ループ) ▼▼▼
            if jobs_completed == total_jobs then
              local end_job_time = os.clock()
              uep_log.info("All %d workers finished in %.4f seconds.", total_jobs, end_job_time - start_time)
              
              if #job_stderr_logs > 0 then
                uep_log.error("Some workers failed:\n%s", table.concat(job_stderr_logs, "\n\n"))
              end
              
              local worker_results_count = vim.tbl_count(merged_worker_results)
              uep_log.info("Total results from workers: %d", worker_results_count)

              -- [!] `vim.tbl_deep_extend` を `for` ループに置き換え
              uep_log.debug("Manually merging %d worker results into new_details map...", worker_results_count)
              for file_path, data in pairs(merged_worker_results) do
                  new_details[file_path] = data
              end
              
              local final_total_count = vim.tbl_count(new_details)
              -- [!] このログが 54421 になるはず！
              uep_log.info("Header parsing complete. Total symbols (files in map): %d", final_total_count) 
              progress:stage_update("header_analysis_detail", total_header_file, "Header analysis complete.")
              
              on_complete(true, new_details)
            end
            -- ▲▲▲ 修正完了 ▲▲▲
          end,
        })
        
        if job_id <= 0 then
            uep_log.error("Failed to start worker job #%d.", i)
            jobs_completed = jobs_completed + 1
            all_jobs_started = false
        else
            uep_log.debug("Started worker job %d (PID: %s) for %d files.", i, vim.fn.jobpid(job_id), #chunk_files)
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
