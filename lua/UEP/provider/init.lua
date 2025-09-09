local unl_log = require("UNL.logging")
local M = {}


M.setup = function()
  local unl_api_ok, unl_api = pcall(require, "UNL.api")
  if unl_api_ok then
    -- 修正: 新しいファイルパスをrequireする
    local project_classes_provider = require("UEP.provider.class") 
    
    unl_api.provider.register({
      capability = "uep.get_project_classes",
      name = "UEP.nvim",
      -- 修正: requireしたモジュールそのものを渡す
      impl = project_classes_provider, 
      priority = 100,
    })

    local log = unl_log.get("UEP")
    if log then
      log.info("Registered 'uep.get_project_classes' provider to UNL.nvim.")
    end
  end
end

return M
