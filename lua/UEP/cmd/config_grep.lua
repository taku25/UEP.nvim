-- lua/UEP/cmd/config_grep.lua (grep.lua からコピーして修正)

local grep_core = require("UEP.cmd.core.grep")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local core_utils = require("UEP.cmd.core.utils")
local fs = require("vim.fs")

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  opts = opts or {}

  -- (スコープ解析ロジックは grep.lua と同じ - 変更なし)
  local requested_scope = "runtime"
  local valid_scopes = { game=true, engine=true, runtime=true, developer=true, editor=true, full=true }
  if opts.scope then
      local scope_lower = opts.scope:lower()
      if valid_scopes[scope_lower] then
          requested_scope = scope_lower
      else
          log.warn("Invalid scope argument '%s' for config_grep. Defaulting to 'runtime'.", opts.scope)
      end
  end
  log.info("Executing :UEP config_grep with scope=%s", requested_scope)

  -- (検索パスの決定ロジック - ほぼ同じ)
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("config_grep: Failed to get project maps: %s", tostring(maps))
      return vim.notify("Error getting project info for config_grep.", vim.log.levels.ERROR)
    end

    local search_paths = {}
    local project_root = maps.project_root
    local engine_root = maps.engine_root

    if not project_root then
        return log.error("config_grep: Project root not found in maps.")
    end

    -- ▼▼▼ [修正箇所 1] ▼▼▼
    -- 検索するサブディレクトリを "Config" のみに限定する
    local function add_standard_dirs(root)
        local base = (root == engine_root) and fs.joinpath(engine_root, "Engine") or project_root
        
        -- ★ "Source", "Plugins" などを削除し、"Config" のみに！
        local subdirs = {"Config"} 
        
        for _, subdir in ipairs(subdirs) do
            local path = fs.joinpath(base, subdir)
            if vim.fn.isdirectory(path) == 1 then
                table.insert(search_paths, path)
            end
        end
    end
    -- ▲▲▲ 修正完了 1 ▲▲▲

    -- (スコープ別のパス追加ロジック - 変更なし)
    if requested_scope == "game" then
      add_standard_dirs(project_root)
    elseif requested_scope == "engine" then
      if engine_root then add_standard_dirs(engine_root)
      else log.warn("config_grep: Engine root not found for Engine scope.") end
    elseif requested_scope == "full" or requested_scope == "runtime" or requested_scope == "developer" or requested_scope == "editor" then
       -- .ini ファイルはスコープに関わらず Game/Engine 両方探すのが親切
       add_standard_dirs(project_root)
       if engine_root then add_standard_dirs(engine_root)
       else log.warn("config_grep: Engine root not found.") end
    end

    -- (重複削除ロジック - 変更なし)
    local seen = {}; local unique_paths = {}
    for _, path in ipairs(search_paths) do if not seen[path] then table.insert(unique_paths, path); seen[path] = true end end
    search_paths = unique_paths

    if #search_paths == 0 then
        return log.warn("config_grep: No valid 'Config' directories found for scope '%s'.", requested_scope)
    end

    -- ▼▼▼ [修正箇所 2] ▼▼▼
    -- grep_core を呼び出す際に、拡張子を上書きする
    grep_core.start_live_grep({
      search_paths = search_paths,
      title = string.format("Live Grep Config (%s)", requested_scope:gsub("^%l", string.upper)),
      initial_query = "",
      
      -- ★ 拡張子を "ini" のみに限定する
      include_extensions = { "ini" }, 
    })
    -- ▲▲▲ 修正完了 2 ▲▲▲
  end)
end

return M
