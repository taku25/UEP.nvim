-- lua/UEP/core/refresh_project.lua (分析官)

local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local fs = require("vim.fs")
local unl_analyzer = require("UNL.analyzer.build_cs")
local uep_graph = require("UEP.graph")
local uep_log = require("UEP.logger")

local M = {}

---
-- モジュール解析とハッシュ計算を行うコアロジック。
-- 元々 refresh.lua にあった analyze_and_get_project_data 関数。
-- @param root_path string
-- @param type "Game" | "Engine"
-- @param engine_cache table | nil
-- @param progress table
-- @param on_complete fun(ok: boolean, new_data: table|nil)
function M.analyze(root_path, type, engine_cache, progress, on_complete)
  local search_paths
  if type == "Game" then
    search_paths = { fs.joinpath(root_path, "Source"), fs.joinpath(root_path, "Plugins") }
  else -- Engine
    search_paths = { fs.joinpath(root_path, "Engine", "Source"), fs.joinpath(root_path, "Engine", "Plugins") }
  end

  progress:stage_define("scan_modules", 1)
  progress:stage_update("scan_modules", 0, "Scanning for Build.cs files...")

  -- 検索パス内の重複を排除
  local unique_search_paths = {}
  local seen_paths = {}
  for _, path in ipairs(search_paths) do
    if not seen_paths[path] and vim.fn.isdirectory(path) == 1 then
      table.insert(unique_search_paths, path)
      seen_paths[path] = true
    end
  end

  local fd_cmd = { "fd", "--absolute-path", "--type", "f", "Build.cs", unpack(unique_search_paths) }
  local build_cs_files = {}
  vim.fn.jobstart(fd_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(build_cs_files, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 or #build_cs_files == 0 then
        progress:stage_update("scan_modules", 1, "No modules found.")
        on_complete(true, nil) -- モジュールがなくてもエラーではない
        return
      end
      progress:stage_update("scan_modules", 1, ("Found %d modules."):format(#build_cs_files))

      local co = coroutine.create(function()
        progress:stage_define("parse_modules", #build_cs_files)
        local modules_meta = {}
        for i, raw_path in ipairs(build_cs_files) do
          local build_cs_path = unl_path.normalize(raw_path)
          local module_name = vim.fn.fnamemodify(build_cs_path, ":h:t")
          progress:stage_update("parse_modules", i, "Parsing: " .. module_name)
          local module_root = vim.fn.fnamemodify(build_cs_path, ":h")
          local location = build_cs_path:find("/Plugins/", 1, true) and "in_plugins" or (build_cs_path:find("/Source/", 1, true) and "in_source" or "unknown")
          local dependencies = unl_analyzer.parse(build_cs_path)
          modules_meta[module_name] = { name = module_name, path = build_cs_path, module_root = module_root, category = type, location = location, dependencies = dependencies }
          if i % 5 == 0 then coroutine.yield() end
        end
        progress:stage_update("parse_modules", #build_cs_files, "All modules parsed.")
        coroutine.yield()

        progress:stage_define("resolve_deps", 1)
        progress:stage_update("resolve_deps", 0, "Building dependency graph...")
        local modules_with_resolved_deps, _ = uep_graph.resolve_all_dependencies(modules_meta, engine_cache and engine_cache.modules or nil)
        progress:stage_update("resolve_deps", 1, "Dependency resolution complete.")
        coroutine.yield()

        if not modules_with_resolved_deps then
          on_complete(false, nil)
          return
        end

        local content_to_hash = vim.json.encode(modules_with_resolved_deps)
        local data_hash = vim.fn.sha256(content_to_hash)
        local new_data = { generation = data_hash, modules = modules_with_resolved_deps, root = root_path }

        if type == "Game" then
          new_data.uproject_path = unl_finder.project.find_project_file(root_path)
          new_data.link_engine_cache_root = engine_cache and engine_cache.root or nil
        end
        on_complete(true, new_data)
      end)

      local function resume_handler()
        local status, err = coroutine.resume(co)
        if not status then
          uep_log.get().error("Error in project analysis coroutine: %s", tostring(err))
          on_complete(false, nil)
          return
        end
        if coroutine.status(co) ~= "dead" then
          vim.defer_fn(resume_handler, 1)
        end
      end
      resume_handler()
    end
  })
end

return M
