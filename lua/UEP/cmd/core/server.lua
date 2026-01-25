-- lua/UEP/cmd/core/server.lua
local M = {}
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")

---　ぁんばぁてぃってを取得する　(　OSに応じたプレフィックスを付与)
function M.get_server_name()
    local config = uep_config.get()
    local name = config.server.name or "UEP_nvim"
    if vim.fn.has('win32') == 1 then
        if not name:match("^\\\\%.\\pipe\\\\") then
            name = [[\\.\\pipe\\\]] .. name
        end
    end
    return name
end

---　ぁんばぁてぃってが執行中か確認する
function M.is_running()
    local name = M.get_server_name()
    local servers = vim.fn.serverlist()
    for _, s in ipairs(servers) do
        if s == name then
            return true
        end
    end
    return false
end

---　ぁんばぁてぃってを開始する
function M.start()
    local config = uep_config.get()
    if not (config.server and config.server.enable) then
        return false
    end

    if M.is_running() then
        -- uep_log.get().debug("UEP Server is already running.")
        return true
    end

    local name = M.get_server_name()
    local ok, _ = pcall(vim.fn.serverstart, name)
    if ok then
        uep_log.get().info("UEP Server started at: " .. name)
        return true
    else
        uep_log.get().warn("Failed to start UEP Server at: " .. name)
        return false
    end
end

---　ぁんばぁてぃってを停止する
function M.stop()
    local name = M.get_server_name()
    if M.is_running() then
        pcall(vim.fn.serverstop, name)
        uep_log.get().info("UEP Server stopped.")
    end
end

return M
