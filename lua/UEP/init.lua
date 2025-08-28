-- UEP.nvim プラグインのメインエントリーポイント (最終完成版)

-- UNLのコアモジュールをインポート
local unl_log = require("UNL.logging")
local conf_default = require("UEP.config.defaults")

-- UEPの公開APIモジュールをインポート
local api = require("UEP.api")

local M = {}

function M.setup(user_config)
  -- ユーザー設定の型を安全にチェック
  user_config = (user_config and type(user_config) == "table") and user_config or {}

  -- "UEP" という名前で、ロガーと設定の両方を一度に初期化する
  -- これで、UNLライブラリは "UEP" の設定を正しく認識する
  unl_log.setup("UEP", conf_default, user_config)

  local log = unl_log.get("UEP")
  if log then
    log.debug("UEP.nvim setup complete.")
  end


  require("UEP.event.hub").setup()
end

return M
