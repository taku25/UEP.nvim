-- lua/UEP/logger.lua

local M = {}

-- 遅延読み込み用の変数
local unl_logging

-- ダミーロガーを作成する内部関数
local function create_dummy_logger()
  -- メインのロガーがまだ準備できていないことをユーザーに知らせる
  vim.notify("[UEP.nvim] Logger not initialized, using fallback.", vim.log.levels.WARN)
  
  -- vim.notifyを最低限の機能として提供するダミーテーブルを返す
  return {
    notify = function(msg, level)
      level = level or "info"
      local lvl = vim.log.levels[(level:upper())] or vim.log.levels.INFO
      vim.notify("[UEP] " .. tostring(msg), lvl)
    end,
    -- 他のログレベルの関数も、念のため空の関数として定義しておく
    info = function() end,
    warn = function() end,
    error = function() end,
    debug = function() end,
    trace = function() end,
  }
end


M.name = "UEP"

M.get = function()
  if not unl_logging then
    unl_logging = require("UNL.logging")
  end

  -- "UEP"という名前のロガーを探す
  local logger = unl_logging.get(M.name)
  
  -- もし見つかればそれを返す
  if logger then
    return logger
  end
  
  -- ★★★ 見つからなければ、ダミーロガーを返す ★★★
  return create_dummy_logger()
end

return M
