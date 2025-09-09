-- lua/UEP/provider/class.lua (新規作成)

local files_disk_cache = require("UEP.cache.files")
local project_cache = require("UEP.cache.project")
local unl_finder = require("UNL.finder")
local uep_log = require("UEP.logger").get()

-- プロバイダーの実装本体となるテーブル
local M = {}

---
-- capability 'uep.get_project_classes' のリクエストを処理する
-- @param opts table | nil: { project_root = "C:/path/to/project" } (オプショナル)
-- @return table|nil: 結合された header_details テーブル、またはnil
function M.request(opts)
  opts = opts or {}
  
  -- (この関数の中身は変更なし)
  local project_root = opts.project_root or unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    uep_log.warn("get_project_classes: Could not determine project root.")
    return nil
  end
  
  local game_data = project_cache.load(project_root)
  if not game_data then
    uep_log.trace("get_project_classes: Game project cache not found for %s", project_root)
    return nil
  end
  
  local game_files = files_disk_cache.load(project_root)
  local engine_files = nil
  if game_data.link_engine_cache_root then
    engine_files = files_disk_cache.load(game_data.link_engine_cache_root)
  end
  
  local all_header_details = {}
  if engine_files and engine_files.header_details then
    vim.tbl_deep_extend("force", all_header_details, engine_files.header_details)
  end
  if game_files and game_files.header_details then
    vim.tbl_deep_extend("force", all_header_details, game_files.header_details)
  end
  
  uep_log.info("Provided %d header details for project %s", vim.tbl_count(all_header_details), project_root)
  
  return all_header_details
end

return M
