-- lua/UEP/cmd/grep_core.lua
-- UNL.backend.grep_picker を利用してリファクタリングされたバージョン
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
-- 以前の unl_picker や Job の代わりに、新しい grep_picker バックエンドを要求する
local unl_grep_picker = require("UNL.backend.grep_picker")

local M = {}

---
-- Live Grepピッカーの起動をUNLに依頼する。
-- この関数がこのモジュールの唯一の公開APIとなる。
-- @param opts table
--   - search_paths (table, required): 検索対象ディレクトリのリスト
--   - title (string, required): ピッカーウィンドウのタイトル
--   - initial_query (string, optional): ピッカー表示時の初期検索クエリ
function M.start_live_grep(opts)
  -- UNLのgrep_pickerを呼び出す。UIの複雑な処理は全てここで吸収される。
  unl_grep_picker.pick({
    -- UNLバックエンドが必要とするオプションを渡す
    conf = uep_config.get(),
    search_paths = opts.search_paths,
    title = opts.title,
    initial_query = opts.initial_query or "",

    -- ユーザーがピッカーで項目を決定したときの処理を定義する
    on_submit = function(selection)
      if selection and selection.filename and selection.lnum then
        -- 選択されたファイルを指定行で開く
        vim.api.nvim_command("edit +" .. tostring(selection.lnum) .. " " .. vim.fn.fnameescape(selection.filename))
      else
        uep_log.get().warn("Invalid selection received from picker.")
      end
    end,
  })
end

return M
