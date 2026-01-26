-- lua/UEP/provider/struct.lua

local uep_db = require("UEP.db.init")
local db_query = require("UEP.db.query")
local uep_log = require("UEP.logger").get()

local M = {}

-- プロジェクト内の全構造体(struct)を取得し、リストで返す
-- @param opts: { scope = "game"|"engine"|"all" }
function M.request(opts)
  opts = opts or {}
  uep_log.debug("--- UEP Provider 'get_project_structs' CALLED (DB) ---")

  local db = uep_db.get()
  if not db then return nil end

  local scope_filter = ""
  local requested_scope = (opts.scope and opts.scope:lower()) or "all"
  
  -- 簡単のため、スコープフィルタはモジュールテーブルとのJOINで実現
  -- 必要に応じて強化する
  if requested_scope == "game" then
      scope_filter = "AND m.scope = 'Game'"
  elseif requested_scope == "engine" then
      scope_filter = "AND m.scope = 'Engine'"
  end

  local rows = db_query.get_structs(db, scope_filter)
  if not rows then return {} end

  local results = {}
  for _, row in ipairs(rows) do
      table.insert(results, {
          name = row.name,
          base_class = row.base_class,
          path = row.path,
          module = row.module_name,
          type = "struct" 
      })
  end

  uep_log.info("Provider: Found %d structs.", #results)
  return results
end

return M
