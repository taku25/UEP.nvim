local uep_db = require("UEP.db.init")
local db_query = require("UEP.db.query")

local M = {}

function M.request(opts, on_complete)
  opts = opts or {}
  local prefix = opts.prefix
  if not prefix or prefix == "" then 
      if on_complete then on_complete(true, {}) end
      return {} 
  end

  local db = uep_db.get()
  if not db then 
      if on_complete then on_complete(false, "DB not available") end
      return {} 
  end

  local rows = db_query.search_classes_prefix(db, prefix, opts.limit or 50)
  
  if on_complete then
      on_complete(true, rows)
  end
  
  return rows
end

return M
