-- lua/UEP/cmd/core/derived.lua (DB Recursive Query Optimized)

local core_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")
local uep_db = require("UEP.db.init")
local db_query = require("UEP.db.query")

local M = {}

-- Helper: Determine target modules based on scope and dependencies
local function get_target_modules(opts, on_complete)
  local log = uep_log.get()
  opts = opts or {}
  local requested_scope = opts.scope or "runtime"
  local deps_flag = opts.deps_flag or "--deep-deps"

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("derived: Failed to get project maps: %s", tostring(maps))
      if on_complete then on_complete(nil) end
      return
    end

    local all_modules_map = maps.all_modules_map
    local game_name = maps.game_component_name
    local engine_name = maps.engine_component_name

    local target_module_names = {}
    local seed_modules = {}

    -- 1. Determine seed modules based on scope
    if requested_scope == "game" then
      for n, m in pairs(all_modules_map) do if m.owner_name == game_name then seed_modules[n] = true end end
    elseif requested_scope == "engine" then
      for n, m in pairs(all_modules_map) do if m.owner_name == engine_name then seed_modules[n] = true end end
    elseif requested_scope == "runtime" then
      for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
    elseif requested_scope == "developer" then
      for n, m in pairs(all_modules_map) do if m.type == "Runtime" or m.type == "Developer" then seed_modules[n] = true end end
    elseif requested_scope == "editor" then
      for n, m in pairs(all_modules_map) do
        if m.type and m.type ~= "Program" then
          local ct = m.type:match("^%s*(.-)%s*$"):lower()
          if ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly" then
            seed_modules[n] = true
          end
        end
      end
    elseif requested_scope == "full" then
      for n,_ in pairs(all_modules_map) do seed_modules[n] = true end
    else -- Default to runtime
      for n, m in pairs(all_modules_map) do if m.type == "Runtime" then seed_modules[n] = true end end
    end

    -- 2. Add dependencies
    if deps_flag == "--no-deps" or requested_scope == "full" then
      target_module_names = seed_modules
    else
      local deps_key = (deps_flag == "--deep-deps") and "deep_dependencies" or "shallow_dependencies"
      local modules_to_process = vim.tbl_keys(seed_modules)
      local processed = {}

      while #modules_to_process > 0 do
        local current_name = table.remove(modules_to_process)
        if not processed[current_name] then
          processed[current_name] = true
          target_module_names[current_name] = true
          local current_meta = all_modules_map[current_name]
          if current_meta and current_meta[deps_key] then
            for _, dep_name in ipairs(current_meta[deps_key]) do
              if not processed[dep_name] then
                local dep_meta = all_modules_map[dep_name]
                if dep_meta then
                  local should_add = false
                  -- Scope check for dependencies
                  if requested_scope == "game" then should_add = (dep_meta.owner_name == game_name)
                  elseif requested_scope == "engine" then should_add = (dep_meta.owner_name == engine_name)
                  elseif requested_scope == "runtime" then should_add = (dep_meta.type == "Runtime")
                  elseif requested_scope == "developer" then should_add = (dep_meta.type == "Runtime" or dep_meta.type == "Developer")
                  elseif requested_scope == "editor" then
                    if dep_meta.type and dep_meta.type ~= "Program" then
                      local ct = dep_meta.type:match("^%s*(.-)%s*$"):lower()
                      should_add = ct=="runtime" or ct=="developer" or ct:find("editor",1,true) or ct=="uncookedonly"
                    end
                  end
                  
                  if should_add then
                    table.insert(modules_to_process, dep_name)
                  end
                end
              end
            end
          end
        end
      end
    end

    if on_complete then on_complete(target_module_names) end
  end)
end

---
-- Get all classes based on scope/deps
function M.get_all_classes(opts, on_complete)
  local log = uep_log.get()
  local start_time = os.clock()
  
  get_target_modules(opts, function(target_module_names)
    if not target_module_names or vim.tbl_count(target_module_names) == 0 then
      log.warn("derived.get_all_classes: No modules matched the filter.")
      if on_complete then on_complete({}) end
      return
    end

    local db = uep_db.get()
    if not db then
        log.error("derived.get_all_classes: DB not available.")
        if on_complete then on_complete(nil) end
        return
    end

    local target_module_list = vim.tbl_keys(target_module_names)
    local raw_classes = db_query.get_classes_in_modules(db, target_module_list)
    
    local all_symbols = {}
    for _, row in ipairs(raw_classes) do
        table.insert(all_symbols, {
            display = row.class_name,
            class_name = row.class_name,
            base_class = row.base_class,
            file_path = row.file_path,
            path = row.file_path,
            lnum = row.line_number or 1,
            filename = row.file_path,
            symbol_type = row.symbol_type
        })
    end

    local end_time = os.clock()
    log.info("derived.get_all_classes finished in %.4f seconds. Found %d symbols.", end_time - start_time, #all_symbols)

    table.sort(all_symbols, function(a, b) return (a.class_name or "") < (b.class_name or "") end)
    if on_complete then on_complete(all_symbols) end
  end)
end

---
-- Get derived classes recursively using DB CTE
function M.get_derived_classes(base_class_name, opts, on_complete)
  local log = uep_log.get()
  
  get_target_modules(opts, function(target_module_names)
    if not target_module_names then
      if on_complete then on_complete(nil) end
      return
    end

    local db = uep_db.get()
    if not db then
        if on_complete then on_complete(nil) end
        return
    end

    -- Use recursive SQL query
    local raw_derived = db_query.get_recursive_derived_classes(db, base_class_name)
    
    -- sqlite.lua fix: Handle boolean return (true = success but no rows?)
    if type(raw_derived) == "boolean" then
        raw_derived = {}
    end

    if not raw_derived then
      if on_complete then on_complete({}) end
      return
    end

    -- Filter by module scope in Lua
    local filtered_symbols = {}
    for _, row in ipairs(raw_derived) do
      if target_module_names[row.module_name] then
        table.insert(filtered_symbols, {
            display = row.class_name,
            class_name = row.class_name,
            base_class = row.base_class,
            file_path = row.file_path,
            path = row.file_path,
            lnum = row.line_number or 1,
            filename = row.file_path,
            symbol_type = row.symbol_type
        })
      end
    end

    table.sort(filtered_symbols, function(a, b) return (a.class_name or "") < (b.class_name or "") end)
    if on_complete then on_complete(filtered_symbols) end
  end)
end

---
-- Get inheritance chain recursively using DB CTE
function M.get_inheritance_chain(child_symbol_name, opts, on_complete)
  local log = uep_log.get()
  
  get_target_modules(opts, function(target_module_names)
    if not target_module_names then
      if on_complete then on_complete(nil) end
      return
    end

    local db = uep_db.get()
    if not db then
        if on_complete then on_complete(nil) end
        return
    end

    local raw_chain = db_query.get_recursive_parent_classes(db, child_symbol_name)
    
    -- sqlite.lua fix: Handle boolean return
    if type(raw_chain) == "boolean" then
        raw_chain = {}
    end

    if not raw_chain then
      if on_complete then on_complete({}) end
      return
    end

    local filtered_chain = {}
    for _, row in ipairs(raw_chain) do
      if target_module_names[row.module_name] then
        table.insert(filtered_chain, {
            display = row.class_name,
            class_name = row.class_name,
            base_class = row.base_class,
            file_path = row.file_path,
            path = row.file_path,
            lnum = row.line_number or 1,
            filename = row.file_path,
            symbol_type = row.symbol_type
        })
      end
    end

    -- Note: raw_chain is already ordered by level (distance from child)
    if on_complete then on_complete(filtered_chain) end
  end)
end

return M
