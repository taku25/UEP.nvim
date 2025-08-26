-- lua/UEP/config.lua
local M = {}

M.name = "UEP"

M.get = function()
  -- 常に"UEP"という名前で、UNLの設定システムを呼び出す
  return require("UNL.config").get(M.name)
end

return M
