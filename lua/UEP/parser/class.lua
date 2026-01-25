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
function M.parse_headers_async(existing_header_details, header_files, progress, on_complete)
  local uep_log = uep_logger_module.get()
  local unl_api = require("UNL.api")
  local start_time = os.clock()

  local new_details = {} 
  existing_header_details = existing_header_details or {}
  local files_to_parse = {} 
  
  local total_header_file = #header_files
  uep_log.debug("parse_headers_async (Rust Scanner): Starting check for %d files.", total_header_file)
  progress:stage_define("header_analysis_detail", total_header_file)

  local BATCH_SIZE = 1000
  local current_idx = 1
  
  local function process_mtime_batch()
      local batch_end = math.min(current_idx + BATCH_SIZE - 1, total_header_file)
      for i = current_idx, batch_end do
          local file_path = header_files[i]
          if i % 1000 == 0 then
             progress:stage_update("header_analysis_detail", i, ("Checking mtime: %s (%d/%d)..."):format(vim.fn.fnamemodify(file_path, ":t"), i, total_header_file))
          end
          local stat = vim.loop.fs_stat(file_path)
          if stat then
              local current_mtime = stat.mtime.sec
              local existing_entry = existing_header_details[file_path]
              if not (existing_entry and existing_entry.mtime and existing_entry.mtime == current_mtime) then
                table.insert(files_to_parse, {
                    path = file_path,
                    mtime = current_mtime,
                    old_hash = (existing_entry and existing_entry.file_hash) or nil
                })
              end
          end
      end
      current_idx = batch_end + 1
      if current_idx <= total_header_file then
          vim.schedule(process_mtime_batch)
      else
          local files_to_parse_count = #files_to_parse
          if files_to_parse_count == 0 then
            progress:stage_update("header_analysis_detail", total_header_file, "All headers up-to-date.")
            on_complete(true, new_details)
            return
          end

          uep_log.info("Starting Rust scanner for %d files...", files_to_parse_count)
          local processed_count = 0
          
          unl_api.scanner.run_async(files_to_parse, function(res)
              -- on_result: 1ファイルごとに呼ばれる
              if res.status == "parsed" and res.data then
                  new_details[res.path] = {
                      classes = res.data.classes,
                      file_hash = res.data.new_hash,
                      mtime = res.mtime
                  }
              end
              processed_count = processed_count + 1
              if processed_count % 100 == 0 then
                  progress:stage_update("header_analysis_detail", processed_count, ("Analyzing headers (Rust): %d/%d"):format(processed_count, files_to_parse_count))
              end
          end, function(ok)
              -- on_complete: 全て完了
              local end_time = os.clock()
              uep_log.info("Rust scanner finished in %.4f seconds (status: %s).", end_time - start_time, tostring(ok))
              on_complete(ok, new_details)
          end)
      end
  end

  vim.schedule(process_mtime_batch)
end


return M
