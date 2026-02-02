local unl_api = require("UNL.api")

local M = {}

function M.request(opts, on_complete)
  unl_api.db.get_project_structs(opts, function(result, err)
    if err then
      if on_complete then on_complete(false, err) end
    else
      if on_complete then on_complete(true, result) end
    end
  end)
end

return M