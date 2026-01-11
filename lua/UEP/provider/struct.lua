-- lua/UEP/provider/struct.lua

local uep_db = require("UEP.db.init")
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

  -- symbol_type = 'struct' のものを検索
  local sql = string.format([[
      SELECT c.name, c.base_class, f.path, m.name as module_name
      FROM classes c
      JOIN files f ON c.file_id = f.id
      JOIN modules m ON f.module_id = m.id
      WHERE c.symbol_type = 'struct' %s
      ORDER BY c.name ASC
  ]], scope_filter)

  local rows = db:eval(sql)
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
