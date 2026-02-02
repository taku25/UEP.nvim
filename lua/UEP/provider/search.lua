local unl_api = require("UNL.api")

local M = {}

function M.request(opts, on_complete)
  opts = opts or {}
  local prefix = opts.prefix
  if not prefix or prefix == "" then 
      if on_complete then on_complete(true, {}) end
      return {} 
  end

  unl_api.db.search_classes_prefix(prefix, opts.limit or 50, function(rows, err)
    if err then
        if on_complete then on_complete(false, err) end
        return
    end
    
    if on_complete then
        on_complete(true, rows or {})
    end
  end)
end

return M
