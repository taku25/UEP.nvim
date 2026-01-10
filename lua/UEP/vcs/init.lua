-- lua/UEP/vcs/init.lua
local M = {}

local providers = {
  { name = "git", module = require("UEP.vcs.git") },
  { name = "p4", module = require("UEP.vcs.p4") },
  { name = "svn", module = require("UEP.vcs.svn") },
}

-- 現在のリビジョンを取得する
-- 最初に見つかった有効なVCSプロバイダーのリビジョンを返す
function M.get_revision(root_path, on_complete)
  local function try_provider(idx)
    if idx > #providers then
        -- All providers failed
        on_complete(nil, nil)
        return
    end

    local provider = providers[idx]
    provider.module.get_revision(root_path, function(rev)
        if rev then
            on_complete(rev, provider.name)
        else
            -- Try next provider
            try_provider(idx + 1)
        end
    end)
  end

  try_provider(1)
end

return M
