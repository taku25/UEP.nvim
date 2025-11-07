-- lua/UEP/cmd/program_grep.lua (疑似モジュール検索対応版)

local grep_core = require("UEP.cmd.core.grep")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local uep_config = require("UEP.config")
local core_utils = require("UEP.cmd.core.utils")

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  log.info("Executing :UEP program_grep...")

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("program_grep: Failed to get project info: %s", tostring(maps))
      return vim.notify("Error getting project info.", vim.log.levels.ERROR)
    end

    local programs_modules = maps.programs_modules_map or {}
    local search_paths = {}

    -- 1. [既存] 実モジュールのルートパスを追加
    for mod_name, mod_meta in pairs(programs_modules) do
      if mod_meta.module_root then
        table.insert(search_paths, mod_meta.module_root)
      else
        log.warn("program_grep: Module '%s' is missing module_root.", mod_name)
      end
    end

    -- ▼▼▼ [ここから追加] ▼▼▼

    -- 2. Game と Plugin の "疑似モジュール" のルートパスを追加
    for comp_name_hash, comp_meta in pairs(maps.all_components_map) do
      if (comp_meta.type == "Game" or comp_meta.type == "Plugin") and comp_meta.root_path then
        -- Game/Plugin ルート直下の Programs ディレクトリを検索パスに追加
        local programs_dir = fs.joinpath(comp_meta.root_path, "Programs")
        if vim.fn.isdirectory(programs_dir) == 1 then
          table.insert(search_paths, programs_dir)
        end
      end
    end

    -- 3. Engine の "Programs" 疑似モジュールのルートパスを追加
    if maps.engine_root then
      -- .../Engine/Source/Programs を検索パスに追加
      local engine_programs_root = fs.joinpath(maps.engine_root, "Engine", "Source", "Programs")
      if vim.fn.isdirectory(engine_programs_root) == 1 then
        table.insert(search_paths, engine_programs_root)
      end
    end
    -- ▲▲▲ [追加完了] ▲▲▲

    -- 4. [修正] 最終チェック
    if #search_paths == 0 then
      log.warn("program_grep: No program modules or program directories found.")
      return vim.notify("No program files/modules found.", vim.log.levels.WARN)
    end

    log.info("program_grep: Starting grep in %d program module/directories.", #search_paths)

    -- Call core grep with the identified program module roots
    grep_core.start_live_grep({
      search_paths = search_paths,
      title = "Live Grep (Programs)",
      initial_query = "",
    })
  end)
end

return M
