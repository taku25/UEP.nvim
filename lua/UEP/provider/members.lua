local unl_api = require("UNL.api")
local uep_log = require("UEP.logger").get()

local M = {}

function M.request(opts, on_complete)
  opts = opts or {}
  local class_name = opts.class_name
  if not class_name or class_name == "" then 
      if on_complete then on_complete(true, {}) end
      return {} 
  end

  -- UNL.api.db 経由で直接アクセス
  unl_api.db.get_members_recursive(class_name, opts.current_namespace, function(rows, err)
    if err then
        uep_log.error("Provider members: RPC error: %s", tostring(err))
        if on_complete then on_complete(false, err) end
        return
    end

    if not rows then rows = {} end

    -- 戻り値型の簡易パッチ (必要に応じて)
    for _, row in ipairs(rows) do
        if (not row.return_type or row.return_type == "") and row.detail and row.detail ~= "" then
            local type_guess = row.detail:match("^%s*([A-Z]%w+)")
            if type_guess then
                row.return_type = type_guess
            end
        end
    end

    if on_complete then
        on_complete(true, rows)
    end
  end)
end

return M
