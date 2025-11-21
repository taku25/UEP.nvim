-- lua/UEP/cmd/core/ui_control.lua (新規作成)

local unl_context = require("UNL.context")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local uep_log = require("UEP.logger").get()
local unl_api = require("UNL.api") -- プロバイダー呼び出しに必要

local M = {}

---
-- UEPのツリーリクエストを保存し、UNXまたはNeo-treeの起動を制御する。
-- @param payload table UEP treeコマンドで生成されたペイロード
function M.handle_tree_request(payload)
    
    local has_unx_provider = false
    local is_unx_open = false

    -- 1. UNXプロバイダーの状態をチェック
    local unl_api_ok, unl_api_mod = pcall(require, "UNL.api")
    if unl_api_ok then
        local is_open_res = unl_api_mod.provider.request("unx.is_open", { name = "UEP.nvim" })
        if is_open_res ~= nil then
            has_unx_provider = true
            is_unx_open = is_open_res
        end
    end

    -- 2. UNXへのイベントペイロードをコンテキストに保存
    unl_context.use("UEP"):key("pending_request:" .. "neo-tree-uproject"):set("payload", payload)
    unl_events.publish(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, payload )
    
    -- 3. UNXが存在する場合、状態に応じて開く要求を出す
    if has_unx_provider then
        uep_log.info("UNX provider detected (is_open: %s). Requesting open if closed.", tostring(is_unx_open))
        if not is_unx_open then
            -- UNXが開いていなければ、UNXに開くよう要求
            unl_api_mod.provider.request("unx.open", { name = "UEP.nvim" })
        end
    end
    
    -- 4. 1フレーム後にフォールバックロジックを実行 (Neo-tree)
    vim.schedule(function()
        if not has_unx_provider then
            uep_log.warn("UNX.nvim provider not found. Falling back to neo-tree.")
            local ok, neo_tree_cmd = pcall(require, "neo-tree.command")
            if ok then
              neo_tree_cmd.execute({ source = "uproject", action = "focus" })
            else
              uep_log.warn("neo-tree command not found.")
            end
        end
    end)
end

return M
