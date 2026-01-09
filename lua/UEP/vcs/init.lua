-- lua/UEP/vcs/init.lua
local M = {}

local providers = {
  { name = "git", module = require("UEP.vcs.git") },
  -- { name = "p4", module = require("UEP.vcs.p4") }, -- Future support
  -- { name = "svn", module = require("UEP.vcs.svn") }, -- Future support
}

-- 現在のリビジョンを取得する
-- 最初に見つかった有効なVCSプロバイダーのリビジョンを返す
function M.get_revision(root_path, on_complete)
  -- 現在はGitのみ対応
  -- 複数のVCSが検出された場合どうするか？通常は1つのみ。
  -- 優先度順にチェック
  
  -- TODO: ConfigでVCSを明示的に指定、または無効化できるようにする
  
  -- 非同期で順番に試すのが面倒なので、Gitのみ決め打ちで実装
  -- 将来的には再帰的にチェックする
  
  providers[1].module.get_revision(root_path, function(rev)
    if rev then
      on_complete(rev, "git")
    else
      -- 次のプロバイダーへ(今はなし)
      on_complete(nil, nil)
    end
  end)
end

return M
