local core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_progress = require("UNL.backend.progress")
local unl_picker = require("UNL.backend.picker")
local uep_db = require("UEP.db.init")
local unl_finder = require("UNL.finder")
local unl_cache_core = require("UNL.cache.core")
local fs = require("vim.fs")

local M = {}

-- ============================================================
-- 1. Helper Functions (File I/O & Logic)
-- ============================================================

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  -- Detect UTF-16 LE BOM
  if content:sub(1, 2) == "\255\254" then
    local converted = vim.iconv(content, "utf-16le", "utf-8")
    if converted then content = converted end
  end
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
  local rel = relative_path:gsub("\\", "/")
  -- Check for absolute path
  if rel:match("^%a:") or rel:match("^/") then
    return vim.fs.normalize(rel)
  end
  local base = base_dir:gsub("\\", "/")
  return vim.fs.normalize(base .. "/" .. rel)
end

-- ============================================================
-- 2. Shadow RSP Creation Logic (Sync per file)
-- ============================================================

local function get_cached_path(cache_dir, original_path)
  local name = vim.fn.fnamemodify(original_path, ":t")
  local dir = vim.fn.fnamemodify(original_path, ":h")
  local hash = vim.fn.sha256(dir):sub(1, 8)
  return string.format("%s/%s_%s", cache_dir, hash, name)
end

local function create_shadow_shared_rsp(source_path, dest_path)
  -- Optimization: Check mtime
  local src_stat = vim.loop.fs_stat(source_path)
  local dst_stat = vim.loop.fs_stat(dest_path)
  if src_stat and dst_stat and dst_stat.mtime.sec >= src_stat.mtime.sec then
      return true -- Already up-to-date
  end

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

local function create_shadow_rsp(original_rsp_path, shadow_rsp_path, shared_rsp_lookup, cache_dir)
  -- Optimization: Check mtime
  local src_stat = vim.loop.fs_stat(original_rsp_path)
  local dst_stat = vim.loop.fs_stat(shadow_rsp_path)
  if src_stat and dst_stat and dst_stat.mtime.sec >= src_stat.mtime.sec then
      return true -- Already up-to-date
  end

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
        local shadow_shared = get_cached_path(cache_dir, original_shared)
        create_shadow_shared_rsp(original_shared, shadow_shared)
        return prefix .. shadow_shared .. suffix
    end

    return prefix .. resolve_relative_path(rsp_dir, rel_path) .. suffix
  end)

  return write_file(shadow_rsp_path, new_content)
end

local function create_shadow_rsp_from_template(template_rsp_path, shadow_rsp_path, target_source_path, shared_rsp_lookup, cache_dir)
  -- Optimization: Check mtime
  -- Note: For template-based RSPs, we should ideally check if the target source path inside matches,
  -- but checking mtime is a good first step. If the template hasn't changed, the shadow likely doesn't need to.
  -- However, if we switch projects or something, the target source might be different for the same shadow path?
  -- No, shadow path includes source filename usually.
  local src_stat = vim.loop.fs_stat(template_rsp_path)
  local dst_stat = vim.loop.fs_stat(shadow_rsp_path)
  if src_stat and dst_stat and dst_stat.mtime.sec >= src_stat.mtime.sec then
      return true -- Already up-to-date
  end

  local content = read_file(template_rsp_path)
  if not content then return false end

  local rsp_dir = vim.fn.fnamemodify(template_rsp_path, ":h")

  -- 1. Standard Path Resolution
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
        local shadow_shared = get_cached_path(cache_dir, original_shared)
        create_shadow_shared_rsp(original_shared, shadow_shared)
        return prefix .. shadow_shared .. suffix
    end

    return prefix .. resolve_relative_path(rsp_dir, rel_path) .. suffix
  end)

  -- 2. Inject Target Source Path
  -- Replace existing /Tp"..." or /Tp "..." with the new target
  -- Note: We use forward slashes for the path to be safe
  local safe_target = target_source_path:gsub("\\", "/")
  
  -- Try replacing quoted /Tp
  local replaced = false
  new_content, count = new_content:gsub('(/Tp%s*")([^"]+)(")', '/Tp "' .. safe_target .. '"')
  if count > 0 then replaced = true end
  
  if not replaced then
     -- Try replacing unquoted /Tp (less common in UE but possible)
     -- Actually UE usually quotes.
     -- If no /Tp found, we might need to append it? 
     -- But usually there is one. If not, maybe it's a PCH or something.
     -- Let's append if missing? No, that might break things.
  end

  return write_file(shadow_rsp_path, new_content)
end

-- ============================================================
-- 3. Async Scanning (using vim.fn.jobstart)
-- ============================================================

local function scan_rsps_async(search_roots, target_config, target_name, on_complete)
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
    local p = path:lower():gsub("\\", "/")
    if target_config and not p:find("/" .. target_config:lower() .. "/", 1, true) then
        return false
    end
    if target_name then
        -- Relaxed check: Match "/TargetName" (allows suffixes like UnrealEditorGCD)
        if not p:find("/" .. target_name:lower(), 1, true) then
            return false
        end
    end
    return true
  end

  for _, root in ipairs(roots_to_scan) do
    log.info("Scanning root: %s", root)
    local cmd = { "fd", "--type", "f", "--no-ignore", "--absolute-path", "--ignore-case", "--regex", ".*(\\.obj\\.rsp|\\.Shared\\.rsp)(\\.gcd)?$", root }
    
    local stdout_buffer = ""
    local found_count = 0
    local matched_count = 0
    
    vim.fn.jobstart(cmd, {
      stdout_buffered = false,
      on_stdout = function(_, data)
        if not data then return end
        for _, line in ipairs(data) do
          if line ~= "" then
             found_count = found_count + 1
             local path = line
             if not path:match("%.nvim$") then
                if is_target_config(path) then
                  matched_count = matched_count + 1
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
                else
                   -- log.trace("Skipped RSP (config mismatch): %s", path)
                end
             end
          end
        end
      end,
      on_stderr = function(_, data)
          if data then
             for _, line in ipairs(data) do
                 if line ~= "" then log.warn("fd stderr: %s", line) end
             end
          end
      end,
      on_exit = function()
        log.info("Root scan finished: %s. Found: %d, Matched: %d", root, found_count, matched_count)
        pending_jobs = pending_jobs - 1
        check_done()
      end
    })
  end
end

local function find_clang_cl()
  local is_windows = vim.fn.has("win32") == 1

  -- 1. Check common Visual Studio paths (Windows only, prioritized)
  if is_windows then
      local editions = { "Enterprise", "Professional", "Community" }
      local years = { "2026", "2022", "2019" }
      
      for _, year in ipairs(years) do
        for _, edition in ipairs(editions) do
          local base = string.format("C:/Program Files/Microsoft Visual Studio/%s/%s/VC/Tools/Llvm/x64/bin/clang-cl.exe", year, edition)
          if vim.fn.filereadable(base) == 1 then
            return string.format('"%s"', base)
          end
        end
      end
  end

  -- 2. Check if clang-cl is in PATH
  local exe_name = is_windows and "clang-cl.exe" or "clang-cl"
  if vim.fn.executable(exe_name) == 1 then
    return exe_name
  end

  -- Fallback
  return exe_name
end

-- ============================================================
-- 4. Main Job (Chunk Processing)
-- ============================================================

local function run_job(opts)
  local log = uep_log.get()
  local target_config = opts.config or "Development"
  local target_name = opts.target or "UnrealEditor"
  
  -- DebugGame対策
  local project_config = target_config
  local engine_config = target_config
  if target_config == "DebugGame" then engine_config = "Development" end

  log.info("Generating Compile Commands. Project: %s, Engine: %s", project_config, engine_config)

  local progress, _ = unl_progress.create_for_refresh(uep_config.get(), {
    title = "UEP Compile Commands Gen",
    client_name = "UEP.CompileCommands",
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
    log.info("Project Root: %s", maps.project_root)
    log.info("Engine Root: %s", maps.engine_root)

    progress:stage_update("map", 1, "Map complete.")

    -- 2. Async Scan
    progress:stage_define("scan", 1)
    progress:stage_update("scan", 0, "Scanning RSPs (Async)...")
    
    local search_roots_proj = { fs.joinpath(maps.project_root, "Intermediate", "Build") }
    local search_roots_eng = {}
    if maps.engine_root then
       local eng_path = fs.joinpath(maps.engine_root, "Engine", "Intermediate", "Build")
       table.insert(search_roots_eng, eng_path)
       log.info("Engine Search Path: %s", eng_path)
    else
       log.warn("Engine root not found. Skipping Engine RSP scan.")
    end

    -- Project Scan
    scan_rsps_async(search_roots_proj, project_config, target_name, function(proj_objs, proj_shared, proj_cnt)
      
      -- Engine Scan (nested callback)
      -- Engine target is always UnrealEditor for editor builds
      -- But wait, Engine intermediate files are NOT under "UnrealEditor" target folder usually?
      -- They are often under "UnrealEditor" but sometimes just "Development" or similar?
      -- Actually, for Engine modules, the target name in the path IS "UnrealEditor" (e.g. Intermediate/Build/Win64/UnrealEditor/Development/Core/...)
      -- So "UnrealEditor" should be correct.
      
      local engine_target = "UnrealEditor"
      scan_rsps_async(search_roots_eng, engine_config, engine_target, function(eng_objs, eng_shared, eng_cnt)
        
        -- Merge Results
        local final_obj_rsps = proj_objs
        local final_shared_rsps = proj_shared
        
        for k, v in pairs(eng_objs) do 
            if not final_obj_rsps[k] then final_obj_rsps[k] = {} end
            for _, item in ipairs(v) do table.insert(final_obj_rsps[k], item) end
        end
        for k, v in pairs(eng_shared) do final_shared_rsps[k] = v end
        
        local final_count = proj_cnt + eng_cnt
        
        -- 3. DB Load
        progress:stage_define("fetch", 1)
        progress:stage_update("fetch", 0, "Loading file map from DB...")
        
        local db = uep_db.get()
        local module_file_lookup = {}
        local all_source_files = {}
        
        if db then
            local rows = db:eval([[
                SELECT f.filename, f.path, m.name as module_name 
                FROM files f 
                JOIN modules m ON f.module_id = m.id
            ]])
            if rows then
                for _, row in ipairs(rows) do
                    if not module_file_lookup[row.module_name] then
                        module_file_lookup[row.module_name] = {}
                    end
                    module_file_lookup[row.module_name][row.filename] = row.path
                    table.insert(all_source_files, { path = row.path, filename = row.filename, module = row.module_name })
                end
            end
        else
             log.error("DB not available")
        end
        progress:stage_update("fetch", 1, "DB loaded.")

        -- Create Cache Dir
        local project_hash = vim.fn.sha256(maps.project_root):sub(1, 8)
        local project_name = vim.fn.fnamemodify(maps.project_root, ":t")
        
        local base_cache_dir = unl_cache_core.get_cache_dir(uep_config.get())
        local cache_dir = fs.joinpath(base_cache_dir, project_name .. "_" .. project_hash)
        
        vim.fn.mkdir(cache_dir, "p")
        log.info("Shadow RSP Cache Dir: %s", cache_dir)

        -- 4. Process (Chunked Async Loop)
        -- Determine compiler path
        local compiler_cmd = find_clang_cl()
        if opts.compiler then compiler_cmd = opts.compiler end

        -- Build Module -> RSP lookup for fallback
        local module_rsp_fallback = {}
        for filename, candidates in pairs(final_obj_rsps) do
            for _, rsp_info in ipairs(candidates) do
                if rsp_info.module and not module_rsp_fallback[rsp_info.module] then
                    module_rsp_fallback[rsp_info.module] = rsp_info
                end
            end
        end
        log.info("DB Source Files: %d", #all_source_files)
        log.info("Fallback Map Size: %d", vim.tbl_count(module_rsp_fallback))

        -- Prepare work queue: Use ALL source files from DB + any extra found in RSPs
        local work_queue = {}
        local processed_paths = {}

        -- Add files from DB
        for _, src in ipairs(all_source_files) do
            -- Filter out .cs and header files
            if not src.filename:match("%.cs$") and not src.filename:match("%.h$") and not src.filename:match("%.hpp$") then
                table.insert(work_queue, { 
                    type = "db", 
                    path = src.path, 
                    filename = src.filename, 
                    module = src.module 
                })
                processed_paths[src.path] = true
            end
        end

        -- Add files from RSPs that might not be in DB (e.g. generated files)
        for filename, candidates in pairs(final_obj_rsps) do
            for _, rsp_info in ipairs(candidates) do
                -- We need to resolve the source path to check if it's already processed
                -- This is expensive, so we do it lazily in the loop or just add them as "rsp" type
                table.insert(work_queue, {
                    type = "rsp",
                    filename = filename,
                    info = rsp_info
                })
            end
        end
        
        local total_items = #work_queue
        local processed_count = 0
        local json_entries = {}
        local chunk_size = 50 
        
        local function extract_source_from_rsp(rsp_path)
            local content = read_file(rsp_path)
            if not content then return nil end
            -- Try to find /Tp "path" or /Tp"path"
            local path = content:match('/Tp%s*"([^"]+)"')
            if not path then path = content:match('/Tp"([^"]+)"') end
            
            if path then
                local base_dir = vim.fn.fnamemodify(rsp_path, ":h")
                return resolve_relative_path(base_dir, path)
            end
            return nil
        end

        local function process_chunk()
            local chunk_end = math.min(processed_count + chunk_size, total_items)
            
            for i = processed_count + 1, chunk_end do
                local item = work_queue[i]
                local source_abs_path = nil
                local rsp_path = nil
                local module_name = item.module
                local is_fallback = false

                if item.type == "db" then
                    source_abs_path = item.path
                    -- Try to find exact RSP match
                    local candidates = final_obj_rsps[item.filename]
                    if candidates and #candidates > 0 then
                        rsp_path = candidates[1].path -- Use first match
                    else
                        -- Fallback to module RSP
                        if module_name and module_rsp_fallback[module_name] then
                            rsp_path = module_rsp_fallback[module_name].path
                            is_fallback = true
                        end
                    end
                elseif item.type == "rsp" then
                    -- Existing logic for RSP-driven items
                    local rsp_info = item.info
                    rsp_path = rsp_info.path
                    module_name = rsp_info.module
                    
                    -- Try to resolve source path
                    if module_file_lookup[module_name] and module_file_lookup[module_name][item.filename] then
                        source_abs_path = module_file_lookup[module_name][item.filename]
                    end
                    
                    if not source_abs_path then
                        source_abs_path = extract_source_from_rsp(rsp_path)
                    end
                end

                -- Avoid duplicates if "rsp" item resolves to a path already processed by "db" item
                if source_abs_path and item.type == "rsp" and processed_paths[source_abs_path] then
                    source_abs_path = nil -- Skip
                end

                if source_abs_path and rsp_path then
                    processed_paths[source_abs_path] = true
                    
                    local shadow_rsp_path = ""
                    local success = false

                    if is_fallback then
                        -- Generate a unique shadow RSP for this file based on the fallback template
                        local source_name = vim.fn.fnamemodify(source_abs_path, ":t")
                        local safe_name = source_name .. ".obj.rsp"
                        local src_hash = vim.fn.sha256(source_abs_path):sub(1, 8)
                        shadow_rsp_path = string.format("%s/%s_%s", cache_dir, src_hash, safe_name)
                        
                        success = create_shadow_rsp_from_template(rsp_path, shadow_rsp_path, source_abs_path, final_shared_rsps, cache_dir)
                    else
                        shadow_rsp_path = get_cached_path(cache_dir, rsp_path)
                        success = create_shadow_rsp(rsp_path, shadow_rsp_path, final_shared_rsps, cache_dir)
                    end

                    if success then
                        local work_dir = maps.project_root
                        if maps.engine_root then
                            work_dir = fs.joinpath(maps.engine_root, "Engine", "Source")
                        end
                        
                        -- Normalize paths to forward slashes
                        shadow_rsp_path = shadow_rsp_path:gsub("\\", "/")
                        work_dir = work_dir:gsub("\\", "/")
                        
                        table.insert(json_entries, {
                            file = source_abs_path,
                            directory = work_dir,
                            command = string.format('%s @"%s"', compiler_cmd, shadow_rsp_path)
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
                    -- Ensure the file is not hidden (Windows)
                    if vim.fn.has("win32") == 1 then
                        vim.fn.system({"attrib", "-h", out_path})
                    end

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
      kind = "uep_gen_compile_commands_fast", title = "Select Compile Commands Config",
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
