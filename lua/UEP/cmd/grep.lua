-- lua/UEP/cmd/grep.lua
local grep_core = require("UEP.cmd.core.grep")
local uep_log = require("UEP.logger")
local unl_finder = require("UNL.finder")
local uep_config = require("UEP.config")

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  opts = opts or {}

  local scope = opts.category or "game"
  if scope:lower() ~= "game" and scope:lower() ~= "engine" then
    scope = "game"
  end

  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    return log.error("Not in an Unreal Engine project directory.")
  end

  local search_paths = {}
  local conf = uep_config.get()
  
  local include_dirs = conf.include_directory or { "Source", "Plugins", "Config", "Shaders", "Programs" }

  -- Game スコープのパスを追加
  for _, dir in ipairs(include_dirs) do
    local path = vim.fs.joinpath(project_root, dir)
    if vim.fn.isdirectory(path) == 1 then
      table.insert(search_paths, path)
    end
  end

  -- Engine スコープの場合、Engineのパスも追加
  if scope == "engine" then
    local proj_info = unl_finder.project.find_project(project_root)
    local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject, { logger = log }) or nil

    if engine_root then
      for _, dir in ipairs(include_dirs) do
        local path = vim.fs.joinpath(engine_root, "Engine", dir)
        if vim.fn.isdirectory(path) == 1 then
          table.insert(search_paths, path)
        end
      end
    else
      log.warn("Could not determine engine root. Searching in project only.")
    end
  end

  -- ★★★ 2. `grep_core`に処理を委譲する（ここは変更なし） ★★★
  grep_core.start_live_grep({
    search_paths = search_paths,
    title = string.format("Live Grep (%s)", scope),
    initial_query = "",
  })
end

return M
