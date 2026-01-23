-- lua/UEP/provider/init.lua
local unl_log = require("UNL.logging")
local log = require("UEP.logger") 

local M = {}

M.setup = function()
  local unl_api_ok, unl_api = pcall(require, "UNL.api")
  if unl_api_ok then
    -- クラスプロバイダー (既存)
    local project_classes_provider = require("UEP.provider.class") 
    unl_api.provider.register({
      capability = "uep.get_project_classes",
      name = "UEP.nvim",
      impl = project_classes_provider, 
      priority = 100,
    })

    -- ★追加: 継承チェーンプロバイダー (find_parentsロジックベース)
    local inheritance_provider = require("UEP.provider.inheritance")
    unl_api.provider.register({
      capability = "uep.get_inheritance_chain",
      name = "UEP.nvim",
      impl = inheritance_provider,
    })

    -- ★追加: 構造体プロバイダー
    local struct_provider = require("UEP.provider.struct")
    unl_api.provider.register({
      capability = "uep.get_project_structs",
      name = "UEP.nvim",
      impl = struct_provider,
    })

    -- ... (以下の既存登録はそのまま) ...
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
      capability = "uep.update_module_cache",
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

    local config_explorer_provider = require("UEP.provider.config_explorer")
    unl_api.provider.register({
      capability = "uep.get_config_tree_model",
      name = "UEP.nvim",
      impl = config_explorer_provider, 
    })

    local files_provider = require("UEP.provider.files")
    unl_api.provider.register({
      capability = "uep.get_project_items",
      name = "UEP.nvim",
      impl = files_provider,
    })

    -- ★追加: IDE連携
    local ide_provider = require("UEP.provider.ide")
    unl_api.provider.register({
      capability = "uep.open_in_ide",
      name = "UEP.nvim",
      impl = ide_provider,
    })

    local uep_logger = require("UEP.logger").get()
    if uep_logger then
      uep_logger.info("Registered UEP providers to UNL.nvim.")
    end
  end
end

return M
