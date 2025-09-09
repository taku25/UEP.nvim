-- UEP.nvim/lua/UEP/provider/class.lua

local files_disk_cache = require("UEP.cache.files")
local unl_finder = require("UNL.finder")
local uep_log = require("UEP.logger").get()

local M = {}

function M.request(opts)
  opts = opts or {}
  uep_log.debug("--- UEP Provider 'get_project_classes' CALLED (Game Only Mode) ---")

  -- 1. 対象のプロジェクトルートを決定
  local project_root = opts.project_root or unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    uep_log.error("Provider ERROR: Could not determine project root.")
    return nil
  end
  uep_log.debug("Provider: Found project root: %s", project_root)

  -- 2. Gameプロジェクトのファイルキャッシュのみをロードする
  local game_files = files_disk_cache.load(project_root)
  
  -- 3. header_detailsが存在するかチェックして返す
  if game_files and game_files.header_details then
    local final_count = vim.tbl_count(game_files.header_details)
    uep_log.info("Provider: finished. Returning %d header details from Game cache for project %s", final_count, project_root)
    return game_files.header_details
  else
    -- header_detailsが存在しない場合はnilを返す
    uep_log.warn("Provider WARNING: header_details not found in Game file cache for %s. (Hint: run :UEP refresh)", project_root)
    return nil
  end
end

return M
