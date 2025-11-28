-- lua/UEP/provider/init.lua

-- ▼▼▼ この行を追加 ▼▼▼
local unl_log = require("UNL.logging")
local log = require("UEP.logger") 

local M = {}

M.setup = function()
  local unl_api_ok, unl_api = pcall(require, "UNL.api")
  if unl_api_ok then
    -- クラスプロバイダーの登録
    local project_classes_provider = require("UEP.provider.class") 
    unl_api.provider.register({
      capability = "uep.get_project_classes",
      name = "UEP.nvim",
      impl = project_classes_provider, 
      priority = 100,
    })

    -- ツリープロバイダーの登録
    local tree_provider = require("UEP.provider.tree")
    unl_api.provider.register({
      capability = "uep.get_pending_tree_request",
      name = "UEP.nvim",
      impl = tree_provider, 
    })
    unl_api.provider.register({
      capability = "uep.build_tree_model",
      name = "UEP.nvim",
      impl = tree_provider, 
    })
    unl_api.provider.register({
      capability = "uep.load_tree_children",
      name = "UEP.nvim",
      impl = tree_provider,
    })
    unl_api.provider.register({
      capability = "uep.clear_tree_state",
      name = "UEP.nvim",
      impl = tree_provider,
    })

    local build_targets_provider = require("UEP.provider.build_targets")
    unl_api.provider.register({
      capability = "uep.get_build_targets",
      name = "UEP.nvim",
      impl = build_targets_provider, 
      priority = 100,
    })

    -- モジュールリストプロバイダーの登録
    local modules_provider = require("UEP.provider.modules")
    unl_api.provider.register({
      capability = "uep.get_project_modules",
      name = "UEP.nvim",
      impl = modules_provider,
    })

    local class_context_provider = require("UEP.provider.class_context")
    unl_api.provider.register({
      capability = "uep.get_class_context",
      name = "UEP.nvim",
      impl = class_context_provider,
    })

    -- ★★★ [New] Config Explorer プロバイダーの登録 ★★★
    local config_explorer_provider = require("UEP.provider.config_explorer")
    unl_api.provider.register({
      capability = "uep.get_config_tree_model",
      name = "UEP.nvim",
      impl = config_explorer_provider, 
    })
    -- ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★

    local uep_logger = require("UEP.logger").get()
    if uep_logger then
      uep_logger.info("Registered UEP providers to UNL.nvim.")
    end
  end
end

return M
