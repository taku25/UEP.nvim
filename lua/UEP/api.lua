-- lua/UEP/api.lua (薄いAPI層として修正)

local cmd_refresh = require("UEP.cmd.refresh")
local cmd_cd = require("UEP.cmd.cd")
local cmd_delete = require("UEP.cmd.delete")
local cmd_reload_config = require("UEP.cmd.reload_config")
local cmd_files = require("UEP.cmd.files")
local cmd_module_files = require("UEP.cmd.module_files")
local cmd_module_tree = require("UEP.cmd.module_tree")
local cmd_tree = require("UEP.cmd.tree")
local cmd_grep = require("UEP.cmd.grep")
local cmd_module_grep = require("UEP.cmd.module_grep")
local cmd_program_files = require("UEP.cmd.program_files")
local cmd_program_grep = require("UEP.cmd.program_grep")
local cmd_find_derived = require("UEP.cmd.find_derived")
local cmd_find_parents = require("UEP.cmd.find_parents")
local cmd_open_file = require("UEP.cmd.open_file")

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


function M.module_tree(opts)
  cmd_module_tree.execute(opts or {})
end

function M.tree(opts)
  cmd_tree.execute(opts or {})
end

function M.update_module_cache(opts, on_complete)
  if not (opts and opts.module_name) then
    if on_complete then on_complete(false) end
    return
  end
  -- refresh.luaにある実装を直接呼び出す
  require("UEP.cmd.core.refresh_files").update_single_module_cache(opts.module_name, on_complete)
end

function M.grep(opts)
  cmd_grep.execute(opts or {})
end

function M.module_grep(opts)
  cmd_module_grep.execute(opts or {})
end

function M.program_files(opts)
  cmd_program_files.execute(opts or {})
end

function M.program_grep(opts)
  cmd_program_grep.execute(opts or {})
end

function M.find_derived(opts)
  cmd_find_derived.execute(opts or {})
end

function M.find_parents(opts)
  cmd_find_parents.execute(opts or {})
end

function M.open_file(opts)
  cmd_open_file.execute(opts or {})
end

return M
