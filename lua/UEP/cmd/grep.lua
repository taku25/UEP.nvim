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

  -- ▼▼▼ Parse new scope argument (Default: runtime) ▼▼▼
  local requested_scope = "runtime"
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true, programs=true, config=true }
  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          log.warn("Invalid scope argument '%s' for grep. Defaulting to 'runtime'.", opts.scope)
          -- Keep default "runtime"
      end
  end
  log.info("Executing :UEP grep with scope=%s", requested_scope)
  -- ▲▲▲ Scope parsing complete ▲▲▲

  -- ▼▼▼ Determine search paths based on scope ▼▼▼
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("grep: Failed to get project maps: %s", tostring(maps))
      return vim.notify("Error getting project info for grep.", vim.log.levels.ERROR)
    end

    local search_paths = {}
    local project_root = maps.project_root
    local engine_root = maps.engine_root

    if not project_root then
        return log.error("grep: Project root not found in maps.")
    end

    -- 1. Add Module Roots based on Scope
    local all_modules = maps.all_modules_map
    local all_components = maps.all_components_map or {}
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name

    for _, mod_meta in pairs(all_modules) do
        local should_add = false
        if requested_scope == "game" then
            should_add = (mod_meta.owner_name == game_name)
        elseif requested_scope == "engine" then
            should_add = (mod_meta.owner_name == engine_name)
        elseif requested_scope == "runtime" then
            should_add = (mod_meta.type == "Runtime")
        elseif requested_scope == "developer" then
            should_add = (mod_meta.type == "Runtime" or mod_meta.type == "Developer")
        elseif requested_scope == "editor" then
            if mod_meta.type and mod_meta.type ~= "Program" then
                local ct = mod_meta.type:match("^%s*(.-)%s*$"):lower()
                should_add = (ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly")
            end
        elseif requested_scope == "programs" then
            should_add = (mod_meta.type == "Program")
        elseif requested_scope == "config" then
            should_add = false
        elseif requested_scope == "full" then
            should_add = true
        end

        if should_add and mod_meta.module_root then
            table.insert(search_paths, mod_meta.module_root)
        end
    end

    -- 2. Add Pseudo-Module Roots (Config, Shaders, Programs)
    local function add_dir_if_exists(path)
        if vim.fn.isdirectory(path) == 1 then
            table.insert(search_paths, path)
        end
    end

    -- Define what to look for based on scope
    local target_dirs = {} 
    if requested_scope == "config" then
        table.insert(target_dirs, "Config")
    elseif requested_scope == "programs" then
        -- Programs are handled specially below
    else
        table.insert(target_dirs, "Config")
        table.insert(target_dirs, "Shaders")
    end

    -- Collect roots
    local roots = {}
    -- Project
    if requested_scope == "game" or requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" or requested_scope == "config" or requested_scope == "programs" then
        table.insert(roots, { path = project_root, is_engine = false })
    end
    
    -- Engine
    if engine_root and (requested_scope == "engine" or requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" or requested_scope == "config" or requested_scope == "programs") then
        table.insert(roots, { path = fs.joinpath(engine_root, "Engine"), is_engine = true })
    end

    -- Plugins
    for _, comp in pairs(all_components) do
        if comp.type == "Plugin" and comp.root_path then
             local should_add = false
             if requested_scope == "game" then should_add = (comp.owner_name == game_name)
             elseif requested_scope == "engine" then should_add = (comp.owner_name == engine_name)
             elseif requested_scope == "programs" or requested_scope == "config" or requested_scope == "full" then should_add = true
             else should_add = true end 
             
             if should_add then
                 table.insert(roots, { path = comp.root_path, is_engine = false })
             end
        end
    end

    for _, root_info in ipairs(roots) do
        -- Add standard targets (Config, Shaders)
        for _, subdir in ipairs(target_dirs) do
            add_dir_if_exists(fs.joinpath(root_info.path, subdir))
        end

        -- Special handling for Programs
        if requested_scope == "programs" then
            if root_info.is_engine then
                add_dir_if_exists(fs.joinpath(root_info.path, "Source", "Programs"))
            else
                add_dir_if_exists(fs.joinpath(root_info.path, "Programs"))
            end
        end
    end

    -- Remove duplicates (though unlikely with this approach)
    local seen = {}; local unique_paths = {}
    for _, path in ipairs(search_paths) do if not seen[path] then table.insert(unique_paths, path); seen[path] = true end end
    search_paths = unique_paths

    -- ▼▼▼ Optimization: Group paths to avoid command line length limits ▼▼▼
    local function optimize_paths(paths)
        local limit = 6000 -- Conservative limit for Windows command line
        local total_len = 0
        for _, p in ipairs(paths) do total_len = total_len + #p + 1 end
        
        if total_len < limit then return paths end
        
        -- Log suppressed to avoid spam/errors during rapid calls
        -- log.info("grep: Search paths too long (%d chars). Optimizing...", total_len)
        
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
      title = string.format("Live Grep (%s)", requested_scope:gsub("^%l", string.upper)),
      initial_query = "", -- Could add argument parsing for initial query later
    })
  end)
end

return M
