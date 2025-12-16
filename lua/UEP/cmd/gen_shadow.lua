local core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_progress = require("UNL.backend.progress")
local unl_picker = require("UNL.backend.picker")
local module_cache = require("UEP.cache.module")
local projects_cache = require("UEP.cache.projects")
local project_cache = require("UEP.cache.project")
local unl_finder = require("UNL.finder")
local fs = require("vim.fs")

local M = {}

-- ============================================================
-- 1. Helper Functions (File I/O & Logic)
-- ============================================================

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function write_compile_commands_pretty(path, entries)
  local f = io.open(path, "w")
  if not f then return false end
  f:write("[\n")
  for i, entry in ipairs(entries) do
    f:write("  " .. vim.json.encode(entry))
    if i < #entries then f:write(",\n") else f:write("\n") end
  end
  f:write("]\n")
  f:close()
  return true
end

local function resolve_relative_path(base_dir, relative_path)
  local base = base_dir:gsub("\\", "/")
  local rel = relative_path:gsub("\\", "/")
  return vim.fs.normalize(base .. "/" .. rel)
end

-- ============================================================
-- 2. Shadow RSP Creation Logic (Sync per file)
-- ============================================================

local function create_shadow_shared_rsp(source_path, dest_path)
  local content = read_file(source_path)
  if not content then return false end
  local base_dir = vim.fn.fnamemodify(source_path, ":h")

  local new_content = content:gsub('(/I%s*")([^"]+)(")', function(prefix, rel_path, suffix)
    return prefix .. resolve_relative_path(base_dir, rel_path) .. suffix
  end)
  new_content = new_content:gsub('(/FI%s*")([^"]+)(")', function(prefix, rel_path, suffix)
    return prefix .. resolve_relative_path(base_dir, rel_path) .. suffix
  end)
  
  return write_file(dest_path, new_content)
end

local function create_shadow_rsp(original_rsp_path, shadow_rsp_path, shared_rsp_lookup)
  local content = read_file(original_rsp_path)
  if not content then return false end

  local rsp_dir = vim.fn.fnamemodify(original_rsp_path, ":h")

  local new_content = content:gsub('(/I%s*")([^"]+)(")', function(prefix, rel_path, suffix)
    return prefix .. resolve_relative_path(rsp_dir, rel_path) .. suffix
  end)
  
  new_content = new_content:gsub('(/FI%s*")([^"]+)(")', function(prefix, rel_path, suffix)
    return prefix .. resolve_relative_path(rsp_dir, rel_path) .. suffix
  end)

  new_content = new_content:gsub('(@%s*")([^"]+)(")', function(prefix, rel_path, suffix)
    local filename = vim.fn.fnamemodify(rel_path:gsub("\\", "/"), ":t")
    
    if shared_rsp_lookup[filename .. ".gcd"] then
        return prefix .. shared_rsp_lookup[filename .. ".gcd"] .. suffix
    end

    if shared_rsp_lookup[filename] then
        local original_shared = shared_rsp_lookup[filename]
        local shadow_shared = original_shared .. ".nvim"
        create_shadow_shared_rsp(original_shared, shadow_shared)
        return prefix .. shadow_shared .. suffix
    end

    return prefix .. resolve_relative_path(rsp_dir, rel_path) .. suffix
  end)

  return write_file(shadow_rsp_path, new_content)
end

-- ============================================================
-- 3. Async Scanning (using vim.fn.jobstart)
-- ============================================================

local function scan_rsps_async(search_roots, target_config, on_complete)
  local log = uep_log.get()
  local obj_rsps = {}    
  local shared_rsps = {} 
  local total_count = 0
  
  local roots_to_scan = {}
  for _, root in ipairs(search_roots) do
    if vim.fn.isdirectory(root) == 1 then table.insert(roots_to_scan, root) end
  end

  if #roots_to_scan == 0 then
    on_complete(obj_rsps, shared_rsps, 0)
    return
  end

  local pending_jobs = #roots_to_scan
  
  local function check_done()
    if pending_jobs == 0 then
      on_complete(obj_rsps, shared_rsps, total_count)
    end
  end

  local function is_target_config(path)
    if not target_config then return true end
    return path:lower():gsub("\\", "/"):find("/" .. target_config:lower() .. "/", 1, true) ~= nil
  end

  for _, root in ipairs(roots_to_scan) do
    local cmd = { "fd", "--type", "f", "--regex", ".*(\\.obj\\.rsp|\\.Shared\\.rsp)(\\.gcd)?$", root }
    
    local stdout_buffer = ""
    
    vim.fn.jobstart(cmd, {
      stdout_buffered = false, -- ストリームで受け取る
      on_stdout = function(_, data)
        if not data then return end
        for _, line in ipairs(data) do
          if line ~= "" then
             local path = line
             if not path:match("%.nvim$") then
                if is_target_config(path) then
                  local filename = vim.fn.fnamemodify(path, ":t")
                  if filename:match("%.Shared%.rsp") then
                      shared_rsps[filename] = path
                  elseif not filename:match("%.gcd$") then
                      local source_name = filename:gsub("%.obj%.rsp$", "")
                      local parent_dir = vim.fn.fnamemodify(path, ":h")
                      local module_name = vim.fn.fnamemodify(parent_dir, ":t")
                      
                      if not obj_rsps[source_name] then obj_rsps[source_name] = {} end
                      table.insert(obj_rsps[source_name], { path = path, module = module_name })
                      total_count = total_count + 1
                  end
                end
             end
          end
        end
      end,
      on_exit = function()
        pending_jobs = pending_jobs - 1
        check_done()
      end
    })
  end
end

-- ============================================================
-- 4. Main Job (Chunk Processing)
-- ============================================================

local function run_job(opts)
  local log = uep_log.get()
  local target_config = opts.config or "Development"
  
  -- DebugGame対策
  local project_config = target_config
  local engine_config = target_config
  if target_config == "DebugGame" then engine_config = "Development" end

  log.info("Generating Shadow DB. Project: %s, Engine: %s", project_config, engine_config)

  local progress, _ = unl_progress.create_for_refresh(uep_config.get(), {
    title = "UEP Shadow Gen",
    client_name = "UEP.Shadow",
    weights = { map = 0.1, scan = 0.3, fetch=0.1, process = 0.5 }
  })
  progress:open()

  -- 1. Map
  progress:stage_define("map", 1)
  progress:stage_update("map", 0, "Mapping project structure...")
  
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("Failed to get project maps.")
      progress:finish(false)
      return
    end
    progress:stage_update("map", 1, "Map complete.")

    -- 2. Async Scan
    progress:stage_define("scan", 1)
    progress:stage_update("scan", 0, "Scanning RSPs (Async)...")
    
    local search_roots_proj = { fs.joinpath(maps.project_root, "Intermediate", "Build") }
    local search_roots_eng = {}
    if maps.engine_root then
       table.insert(search_roots_eng, fs.joinpath(maps.engine_root, "Engine", "Intermediate", "Build"))
    end

    -- Project Scan
    scan_rsps_async(search_roots_proj, project_config, function(proj_objs, proj_shared, proj_cnt)
      
      -- Engine Scan (nested callback)
      scan_rsps_async(search_roots_eng, engine_config, function(eng_objs, eng_shared, eng_cnt)
        
        -- Merge Results
        local final_obj_rsps = proj_objs
        local final_shared_rsps = proj_shared
        
        for k, v in pairs(eng_objs) do 
            if not final_obj_rsps[k] then final_obj_rsps[k] = {} end
            for _, item in ipairs(v) do table.insert(final_obj_rsps[k], item) end
        end
        for k, v in pairs(eng_shared) do final_shared_rsps[k] = v end
        
        local final_count = proj_cnt + eng_cnt
        
        if final_count == 0 then
          vim.notify("No RSPs found. Build project first?", vim.log.levels.WARN)
          progress:finish(false)
          return
        end
        progress:stage_update("scan", 1, ("Total %d RSPs found."):format(final_count))

        -- 3. Cache Load (Sync is fine here, it's fast)
        progress:stage_define("fetch", 1)
        progress:stage_update("fetch", 0, "Loading module cache...")
        
        local module_file_lookup = {}
        for mod_name, mod_meta in pairs(maps.all_modules_map) do
            local cache = module_cache.load(mod_meta)
            if cache and cache.files and cache.files.source then
                module_file_lookup[mod_name] = {}
                for _, src in ipairs(cache.files.source) do
                    local fname = vim.fn.fnamemodify(src, ":t")
                    module_file_lookup[mod_name][fname] = src
                end
            end
        end
        progress:stage_update("fetch", 1, "Cache loaded.")

        -- 4. Process (Chunked Async Loop)
        progress:stage_define("process", final_count)
        
        -- Flatten the work queue for chunking
        local work_queue = {}
        for filename, candidates in pairs(final_obj_rsps) do
            for _, rsp_info in ipairs(candidates) do
                table.insert(work_queue, { filename = filename, info = rsp_info })
            end
        end
        
        local total_items = #work_queue
        local processed_count = 0
        local json_entries = {}
        local chunk_size = 50 -- 1フレームあたり50ファイル処理
        
        local function process_chunk()
            local chunk_end = math.min(processed_count + chunk_size, total_items)
            
            for i = processed_count + 1, chunk_end do
                local item = work_queue[i]
                local filename = item.filename
                local rsp_info = item.info
                
                local module_name = rsp_info.module
                local rsp_path = rsp_info.path
                local source_abs_path = nil
                
                if module_file_lookup[module_name] then
                    source_abs_path = module_file_lookup[module_name][filename]
                end
                
                if not source_abs_path then
                     for mod, file_map in pairs(module_file_lookup) do
                         if file_map[filename] then
                             source_abs_path = file_map[filename]
                             break
                         end
                     end
                end

                if source_abs_path then
                    local shadow_rsp_path = rsp_path .. ".nvim"
                    if create_shadow_rsp(rsp_path, shadow_rsp_path, final_shared_rsps) then
                        table.insert(json_entries, {
                            file = source_abs_path,
                            directory = maps.project_root,
                            command = string.format('cl.exe @"%s"', shadow_rsp_path)
                        })
                    end
                end
            end
            
            processed_count = chunk_end
            progress:stage_update("process", processed_count, ("Processing... %d/%d"):format(processed_count, total_items))

            if processed_count < total_items then
                -- 次のチャンクをスケジュール（UIブロック回避）
                vim.schedule(process_chunk)
            else
                -- 完了後の処理 (書き込み)
                finish_writing()
            end
        end

        -- 完了処理（ローカル関数）
        function finish_writing()
            progress:stage_define("write", 1)
            progress:stage_update("write", 0, "Writing JSON...")

            if #json_entries > 0 then
                local out_path = fs.joinpath(maps.project_root, "compile_commands.json")
                if write_compile_commands_pretty(out_path, json_entries) then
                    log.info("Generated %d entries (Config: %s).", #json_entries, target_config)
                    vim.notify(("Shadow DB Generated! (%d entries)"):format(#json_entries), vim.log.levels.INFO)
                    
                    vim.schedule(function() 
                        if vim.fn.exists(":LspRestart") == 2 then pcall(vim.cmd, "LspRestart clangd") end 
                    end)
                    progress:finish(true)
                else
                    log.error("Write failed.")
                    progress:finish(false)
                end
            else
                log.warn("No source files matched.")
                progress:finish(false)
            end
        end

        -- 処理開始
        vim.schedule(process_chunk)

      end) -- End Engine Scan
    end) -- End Project Scan
  end) -- End Get Maps
end

-- (get_presets_sync と execute は変更なし)
local function get_presets_sync()
  local cwd = vim.loop.cwd()
  local project_root = unl_finder.project.find_project_root(cwd)
  if not project_root then return {} end
  local project_name = vim.fn.fnamemodify(project_root, ":t")
  local registry = projects_cache.get_project_info(project_name)
  local targets = {}
  if registry and registry.components then
    for _, comp_name in ipairs(registry.components) do
        local cache = project_cache.load(comp_name .. ".project.json")
        if cache and cache.type == "Game" and cache.build_targets then
            for _, t in ipairs(cache.build_targets) do table.insert(targets, t) end
        end
    end
  end
  if #targets == 0 then table.insert(targets, { name = "UnrealEditor", type = "Editor" }) end
  local presets = {}
  local platforms = { "Win64" }
  local configs = { "DebugGame", "Development", "Debug", "Shipping" }
  for _, t in ipairs(targets) do
    for _, p in ipairs(platforms) do
      for _, c in ipairs(configs) do
        table.insert(presets, { name = string.format("%s %s %s", t.name, p, c), target = t.name, platform = p, config = c })
      end
    end
  end
  return presets
end

function M.execute(opts)
  opts = opts or {}
  if opts.has_bang then
    unl_picker.pick({
      kind = "uep_gen_shadow", title = "Select Shadow Config",
      conf = uep_config.get(), items = get_presets_sync(),
      format = function(entry) return entry.name end,
      preview_enabled = false,
      on_submit = function(sel) if sel then opts.target = sel.target; opts.platform = sel.platform; opts.config = sel.config; run_job(opts) end end,
    })
  else
    run_job(opts)
  end
end

return M
