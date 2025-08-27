-- lua/UEP/api.lua (薄いAPI層として修正)

local cmd_refresh = require("UEP.cmd.refresh")
local cmd_cd = require("UEP.cmd.cd")
local cmd_delete = require("UEP.cmd.delete")
local cmd_reload_config = require("UEP.cmd.reload_config")
local cmd_files = require("UEP.cmd.files")
local cmd_module_files = require("UEP.cmd.module_files")
local cmd_tree = require("UEP.cmd.tree")

local M = {}

--- プロジェクトのリフレッシュを開始するAPI
-- @param opts table | nil command_builderから渡される引数テーブル
function M.refresh(opts)
  -- builderがパースしたoptsは { type = "Engine", has_bang = false } のようになる
  cmd_refresh.execute(opts or {})
end

--- 設定をリロードするAPI
function M.reload_config(opts)
  -- 実処理はcmdモジュールに委譲
  cmd_reload_config.execute(opts)
end

function M.cd(opts)
  cmd_cd.execute(opts or {})
end

function M.delete(opts)
  cmd_delete.execute(opts or {})
end

function M.files(opts)
  cmd_files.execute(opts or {})
end

function M.module_files(opts)
  cmd_module_files.execute(opts or {})
end


function M.tree(opts)
  cmd_tree.execute(opts or {})
end
function M.get_solution_roots()
end
return M
