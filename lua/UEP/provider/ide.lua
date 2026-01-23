local cmd = require("UEP.cmd.open_in_ide")

local M = {}

function M.request(opts)
    cmd.execute(opts)
    return true
end

return M
