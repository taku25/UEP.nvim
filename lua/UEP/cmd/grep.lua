-- lua/UEP/cmd/grep.lua (New Scope Handling)

local grep_core = require("UEP.cmd.core.grep")
local uep_log = require("UEP.logger")
-- local unl_finder = require("UNL.finder") -- Use utils instead
local uep_config = require("UEP.config")
local core_utils = require("UEP.cmd.core.utils") -- ★ Use utils
local fs = require("vim.fs") -- ★ Require fs

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  opts = opts or {}

  -- 1. Parse Scope
  local requested_scope = "runtime"
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true, programs=true, config=true }
  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          log.warn("Invalid scope argument '%s' for grep. Defaulting to 'runtime'.", opts.scope)
      end
  end

  -- 2. Parse Deps
  local requested_deps = "--deep-deps"
  local valid_deps = { ["--deep-deps"]=true, ["--shallow-deps"]=true, ["--no-deps"]=true }
  if opts.deps_flag then
      local deps_lower = opts.deps_flag:lower()
      if valid_deps[deps_lower] then
          requested_deps = deps_lower
      else
          log.warn("Invalid deps flag '%s'. Defaulting to '--deep-deps'.", opts.deps_flag)
      end
  end

  -- 3. Parse Mode
  local requested_mode = nil
  local valid_modes = { source=true, config=true, programs=true, shader=true }
  if opts.mode then
      local mode_lower = opts.mode:lower()
      if valid_modes[mode_lower] then
          requested_mode = mode_lower
      else
          log.warn("Invalid mode argument '%s'. Ignoring.", opts.mode)
      end
  end

  log.info("Executing :UEP grep with scope=%s, mode=%s, deps=%s", requested_scope, tostring(requested_mode), requested_deps)

  -- 4. Get Project Maps
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("grep: Failed to get project maps: %s", tostring(maps))
      return vim.notify("Error getting project info for grep.", vim.log.levels.ERROR)
    end

    local search_paths = {}
    local project_root = maps.project_root
    local engine_root = maps.engine_root
    local all_modules = maps.all_modules_map
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name

    -- Helper: Check if path is under root
    local function path_under_root(path, root)
      if not path or not root then return false end
      local p = path:gsub("\\", "/")
      local r = root:gsub("\\", "/")
      if not r:match("/$") then r = r .. "/" end
      return p:sub(1, #r):lower() == r:lower()
    end

    local game_root = (maps.all_components_map[game_name] or {}).root_path
    local engine_root_path = (maps.all_components_map[engine_name] or {}).root_path

    -- 5. Determine Seed Modules
    local seed_modules = {}
    for n, m in pairs(all_modules) do
        local is_match = false
        
        -- Scope Logic
        if requested_scope == "game" then
            is_match = (m.owner_name == game_name or m.component_name == game_name) or path_under_root(m.module_root, game_root)
        elseif requested_scope == "engine" then
            is_match = (m.owner_name == engine_name or m.component_name == engine_name) or path_under_root(m.module_root, engine_root_path)
        elseif requested_scope == "runtime" then
            is_match = (m.type == "Runtime")
        elseif requested_scope == "developer" then
            is_match = (m.type == "Runtime" or m.type == "Developer")
        elseif requested_scope == "editor" then
             if m.type and m.type ~= "Program" then
                local ct = m.type:match("^%s*(.-)%s*$"):lower()
                is_match = (ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly")
             end
        elseif requested_scope == "programs" then
            is_match = (m.type == "Program")
        elseif requested_scope == "config" then
            is_match = true 
        elseif requested_scope == "full" then
            is_match = true
        end

        if is_match then
            -- Mode Logic (Filter modules by type if mode is specific)
            if requested_mode == "programs" then
                if m.type ~= "Program" then is_match = false end
            elseif requested_mode == "source" then
                if m.type == "Program" then is_match = false end
            end
        end

        if is_match then
            seed_modules[n] = true
        end
    end

    -- 6. Expand Dependencies
    local target_modules = seed_modules
    if requested_deps ~= "--no-deps" then
        local deps_key = (requested_deps == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
        for mod_name, _ in pairs(seed_modules) do
            local mod_meta = all_modules[mod_name]
            if mod_meta and mod_meta[deps_key] then
                for _, dep_name in ipairs(mod_meta[deps_key]) do
                    local dep_meta = all_modules[dep_name]
                    if dep_meta then
                        -- Apply Mode Logic to dependencies too
                        local should_add = true
                        if requested_mode == "programs" and dep_meta.type ~= "Program" then should_add = false end
                        if requested_mode == "source" and dep_meta.type == "Program" then should_add = false end
                        
                        if should_add then
                            target_modules[dep_name] = true
                        end
                    end
                end
            end
        end
    end

    -- 7. Collect Paths
    local involved_components = {} -- Set of root paths for Config/Shader lookup

    for mod_name, _ in pairs(target_modules) do
        local m = all_modules[mod_name]
        if m.module_root then
            -- Add Source Path if mode is source or nil
            if not requested_mode or requested_mode == "source" then
                table.insert(search_paths, m.module_root)
            end
            
            -- Track Component Root
            if m.owner_name and maps.all_components_map[m.owner_name] then
                local comp_root = maps.all_components_map[m.owner_name].root_path
                if comp_root then involved_components[comp_root] = true end
            elseif m.component_name and maps.all_components_map[m.component_name] then
                 local comp_root = maps.all_components_map[m.component_name].root_path
                 if comp_root then involved_components[comp_root] = true end
            else
                -- Fallback
                if path_under_root(m.module_root, project_root) then involved_components[project_root] = true end
                if path_under_root(m.module_root, engine_root) then 
                    -- Assuming Engine component root is Engine/
                    local e_root = fs.joinpath(engine_root, "Engine")
                    involved_components[e_root] = true 
                end
            end
        end
    end

    -- Add Config/Shader/Programs dirs from Involved Components
    for comp_root, _ in pairs(involved_components) do
        if requested_mode == "config" or (not requested_mode and requested_scope ~= "programs") then
             local p = fs.joinpath(comp_root, "Config")
             if vim.fn.isdirectory(p) == 1 then table.insert(search_paths, p) end
        end
        if requested_mode == "shader" or (not requested_mode and requested_scope ~= "programs") then
             local p = fs.joinpath(comp_root, "Shaders")
             if vim.fn.isdirectory(p) == 1 then table.insert(search_paths, p) end
        end
    end
    
    -- Remove duplicates
    local seen = {}; local unique_paths = {}
    for _, path in ipairs(search_paths) do if not seen[path] then table.insert(unique_paths, path); seen[path] = true end end
    search_paths = unique_paths

    -- ▼▼▼ Optimization: Group paths to avoid command line length limits ▼▼▼
    local function optimize_paths(paths)
        local limit = 6000 -- Conservative limit for Windows command line
        local total_len = 0
        for _, p in ipairs(paths) do total_len = total_len + #p + 1 end
        
        if total_len < limit then return paths end
        
        -- Define aggregation groups
        local groups = {}
        if engine_root then
            local e_src = fs.joinpath(engine_root, "Engine", "Source")
            groups.engine_runtime = { root = fs.joinpath(e_src, "Runtime"), count = 0 }
            groups.engine_developer = { root = fs.joinpath(e_src, "Developer"), count = 0 }
            groups.engine_editor = { root = fs.joinpath(e_src, "Editor"), count = 0 }
            groups.engine_plugins = { root = fs.joinpath(engine_root, "Engine", "Plugins"), count = 0 }
        end
        if project_root then
            groups.project_source = { root = fs.joinpath(project_root, "Source"), count = 0 }
            groups.project_plugins = { root = fs.joinpath(project_root, "Plugins"), count = 0 }
        end
        
        local optimized = {}
        local covered_indices = {}
        
        for i, p in ipairs(paths) do
            local p_norm = p:gsub("\\", "/"):lower()
            for _, group in pairs(groups) do
                local g_root_norm = group.root:gsub("\\", "/"):lower()
                if p_norm:find(g_root_norm, 1, true) then
                    group.count = group.count + 1
                    covered_indices[i] = true
                    break -- Assign to first matching group
                end
            end
        end
        
        -- Add group roots if they have members
        for _, group in pairs(groups) do
            if group.count > 0 then
                table.insert(optimized, group.root)
            end
        end
        
        -- Add paths that didn't fit in any group
        for i, p in ipairs(paths) do
            if not covered_indices[i] then
                table.insert(optimized, p)
            end
        end
        
        log.info("grep: Optimized paths from %d to %d items.", #paths, #optimized)
        return optimized
    end

    search_paths = optimize_paths(search_paths)
    -- ▲▲▲ Optimization End ▲▲▲

    if #search_paths == 0 then
        return log.warn("grep: No valid search paths found for scope '%s'.", requested_scope)
    end
    log.debug("grep: Determined search paths: %s", vim.inspect(search_paths))
    -- ▲▲▲ Search path determination complete ▲▲▲

    -- Call the core grep function
    grep_core.start_live_grep({
      search_paths = search_paths,
      title = string.format("Live Grep (%s%s%s)", 
        requested_scope:gsub("^%l", string.upper),
        requested_mode and (" ["..requested_mode:gsub("^%l", string.upper).."]") or "",
        requested_deps ~= "--deep-deps" and (" ("..requested_deps..")") or ""
      ),
      initial_query = "", 
    })
  end)
end

return M
