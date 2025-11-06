-- lua/UEP/provider/build_targets.lua
-- UBT.nvim などの外部プラグインに、検出済みのビルドターゲットを提供する

local core_utils = require("UEP.cmd.core.utils")
local project_cache = require("UEP.cache.project")
local uep_log = require("UEP.logger").get()

local M = {}

---
-- UNL.api.provider.request("uep.get_build_targets") から呼び出される
function M.request(opts)
  uep_log.debug("Provider 'uep.get_build_targets' was called.")
  
  local build_targets = nil
  local error_msg = nil

  -- 1. 現在のプロジェクトのマップ（特に game_component_name）を取得
  -- (get_project_maps は同期的コールバックとして動作する)
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      error_msg = tostring(maps)
      return
    end

    if not maps.game_component_name then
      error_msg = "Game component name not found in maps."
      return
    end

    -- 2. Gameコンポーネントのキャッシュをロード
    local game_cache_filename = maps.game_component_name .. ".project.json"
    local game_cache = project_cache.load(game_cache_filename)

    if not game_cache then
      error_msg = "Failed to load game project cache: " .. game_cache_filename
      return
    end
    
    -- 3. build_targets テーブルを取得
    if game_cache.build_targets and type(game_cache.build_targets) == "table" then
      build_targets = game_cache.build_targets
    else
      -- キーが存在しなくてもエラーではない（空リストを返す）
      build_targets = {}
    end
  end)

  if error_msg then
    uep_log.error("Provider 'uep.get_build_targets' failed: %s", error_msg)
    return nil
  end

  uep_log.info("Provider 'uep.get_build_targets' succeeded, returning %d targets.", #build_targets)
  return build_targets
end

return M
