-- lua/UEP/provider/modules.lua (新規作成)

local uep_db = require("UEP.db.init")
local db_query = require("UEP.db.query")
local uep_log = require("UEP.logger").get()

local M = {}

-- unl_providerから呼び出されるメイン関数
function M.request(opts)
  opts = opts or {}
  uep_log.debug("Provider 'uep.get_project_modules' was called.")

  local db = uep_db.get()
  if not db then return nil end

  local rows = db_query.get_modules(db)
  if not rows then return {} end

  local picker_items = {}
  for _, row in ipairs(rows) do
    table.insert(picker_items, {
      name = row.name,
      category = row.scope,
      location = row.type, -- Runtime/Editor etc
      root_path = row.root_path,
    })
  end

  uep_log.info("Provider 'uep.get_project_modules' succeeded, returning %d modules.", #picker_items)
  return picker_items
end

return M
