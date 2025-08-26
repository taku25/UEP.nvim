-- lua/UEP/cmd/reload_config.lua
-- :UEP reloadconfig コマンドの実処理を担うモジュール。

-- UNLのコアモジュールをインポート
local unl_config = require("UNL.config")
local uep_log    = require("UEP.logger")

local M = {}

---
-- 設定のリロード処理を実行する。
-- この関数は UEP.api.reload_config から呼び出される。
-- @param opts table APIから渡されるオプション (現在は未使用だが、将来の拡張性のために受け取る)
--
function M.execute(opts)
  -- UNLのconfigローダーに、キャッシュされている設定を破棄し、
  -- 再度ファイル (.unlrc.json 等) から読み込むよう指示する。
  unl_config.reload_single("UEP")

  local msg = "UEP configuration has been reloaded."

  -- ログと通知の両方で、ユーザーに処理が完了したことをフィードバックする
  uep_log.info(msg)
  vim.notify(msg, vim.log.levels.INFO)
end

return M
