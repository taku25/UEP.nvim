-- lua/UEP/provider/init.lua

-- ▼▼▼ この行を追加します ▼▼▼
local unl_log = require("UNL.logging")
local log = require("UEP.logger") -- 念のためこちらも（もし将来使うなら）

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
      -- capabilityは包括的な名前にしたが、機能ごとに分ける方が明確かもしれない
      -- ここでは例として両方登録しておく（UNL側は同じimplを参照するだけなので問題ない）
      capability = "uep.get_pending_tree_request",
      name = "UEP.nvim",
      impl = tree_provider, 
    })
    unl_api.provider.register({
      capability = "uep.build_tree_model",
      name = "UEP.nvim",
      impl = tree_provider, 
    })

    -- [New] 子ノード遅延読み込みプロバイダーの登録
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
    -- ★ unl_log.get("UEP") ではなく、UEP独自のロガーラッパーを使うのがより良い実践
    local uep_logger = require("UEP.logger").get()
    if uep_logger then
      uep_logger.info("Registered UEP providers to UNL.nvim.")
    end


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
  end
end

return M
