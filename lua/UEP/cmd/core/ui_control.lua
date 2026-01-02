-- lua/UEP/cmd/core/ui_control.lua (新規作成)

local unl_context = require("UNL.context")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")
local uep_logger = require("UEP.logger") -- ★修正: get()をここでは呼ばない
local unl_api = require("UNL.api") -- プロバイダー呼び出しに必要

local M = {}

---
-- UEPのツリーリクエストを保存し、UNXまたはNeo-treeの起動を制御する。
-- @param payload table UEP treeコマンドで生成されたペイロード
function M.handle_tree_request(payload)
    local uep_log = uep_logger.get() -- ★修正: 関数内で取得
    
    -- ★修正: UNX起動前にペイロードを保存する (Cold Start時の競合回避)
    -- Consumer specific
    unl_context.use("UEP"):key("pending_request:" .. "neo-tree-uproject"):set("payload", payload)
    -- Global backup (for safety)
    unl_context.use("UEP"):key("last_tree_payload"):set("payload", payload)
    
    uep_log.debug("Stored pending payload: " .. vim.inspect(payload))
    -- vim.notify("Stored pending payload: " .. vim.inspect(payload), vim.log.levels.INFO) -- Debug

    local has_unx_provider = false
    local is_unx_open = false

    -- 1. UNXプロバイダーの状態をチェック
    local unl_api_ok, unl_api_mod = pcall(require, "UNL.api")
    if unl_api_ok then
        -- ★修正: ok (リクエスト成功フラグ) と is_open_result (結果) の2つの戻り値を受け取る
        has_unx_provider, is_open_result = unl_api_mod.provider.request("unx.is_open", { name = "UEP.nvim" })
        -- ok が true (プロバイダーが見つかり、実行エラーがなかった) かつ
        -- is_open_result が nil でない (プロバイダーが意図した値を返した) 場合
        if is_open_result == false then
            is_unx_open = is_open_result
        end
    end

    -- 3. UNXが存在する場合、状態に応じて開く要求を出す
    if has_unx_provider then
        uep_log.info("UNX provider detected (is_open: %s). Requesting open if closed.", tostring(is_unx_open))
        if not is_unx_open then
            -- open も ok, result で受け取るが、ここでは戻り値は無視して実行
            unl_api_mod.provider.request("unx.open", { name = "UEP.nvim" })
        end
    end
    
    -- 4. 1フレーム後にフォールバックロジックを実行 (Neo-tree)
    -- ★修正: UNXへのイベント通知をここで行う (UNXが開いた後に確実に受け取れるように)
    -- UNXが既に開いている場合でも、イベントを受け取ってリフレッシュする必要がある
    vim.schedule(function()
        unl_events.publish(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, payload )
        
        -- UNXプロバイダーが存在しない場合 (has_unx_provider が false の場合) はneo-treeにフォールバック
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
