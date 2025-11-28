-- lua/UEP/api.lua (薄いAPI層として修正)

local cmd_refresh = require("UEP.cmd.refresh")
local cmd_cd = require("UEP.cmd.cd")
local cmd_delete = require("UEP.cmd.delete")
local cmd_reload_config = require("UEP.cmd.reload_config")
local cmd_files = require("UEP.cmd.files")
local cmd_module_files = require("UEP.cmd.module_files")
local cmd_config_files = require("UEP.cmd.config_files")
local cmd_module_tree = require("UEP.cmd.module_tree")
local cmd_tree = require("UEP.cmd.tree")
local cmd_grep = require("UEP.cmd.grep")
local cmd_module_grep = require("UEP.cmd.module_grep")
local cmd_program_files = require("UEP.cmd.program_files")
local cmd_program_grep = require("UEP.cmd.program_grep")
local cmd_find_derived = require("UEP.cmd.find_derived")
local cmd_find_parents = require("UEP.cmd.find_parents")
local cmd_open_file = require("UEP.cmd.open_file")
local cmd_purge = require("UEP.cmd.purge")
local cmd_cleanup = require("UEP.cmd.cleanup")
local cmd_add_include = require("UEP.cmd.add_include")
local cmd_goto_definition = require("UEP.cmd.goto_definition")
local cmd_classes = require("UEP.cmd.classes")
local cmd_structs = require("UEP.cmd.structs")
local cmd_enums = require("UEP.cmd.enums")
local cmd_config_grep = require("UEP.cmd.config_grep") -- [!] 追加
local cmd_tree_provider = require("UEP.provider.tree") -- [!] clear_tree_state のため
local cmd_system_open = require("UEP.cmd.system_open") -- [New]
local cmd_implement_virtual = require("UEP.cmd.implement_virtual") -- [New]
local cmd_goto_super = require("UEP.cmd.goto_super") -- [New]
local cmd_config_tree = require("UEP.cmd.config_tree") -- ★新規追加
local cmd_find_module = require("UEP.cmd.find_module")

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


function M.close_tree(opts)
  -- 1. UEPの展開状態キャッシュをクリア
  cmd_tree_provider.request({ capability = "uep.clear_tree_state" })
  
  -- 2. neo-tree ウィンドウを閉じる
  local ok, neo_tree_cmd = pcall(require, "neo-tree.command")
  if ok then
    neo_tree_cmd.execute({ action = "close" })
  end
end

function M.update_module_cache(opts, on_complete)
  if not (opts and opts.module_name) then
    if on_complete then on_complete(false) end
    return
  end
  -- refresh.luaにある実装を直接呼び出す
  require("UEP.cmd.core.refresh_modules").update_single_module_cache(opts.module_name, on_complete)
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

function M.purge(opts)
  cmd_purge.execute(opts or {})
end

function M.cleanup(opts)
  cmd_cleanup.execute(opts or {})
end

function M.add_include(opts)
  cmd_add_include.execute(opts or {})
end

function M.goto_definition(opts)
  cmd_goto_definition.execute(opts or {})
end

function M.classes(opts)
  cmd_classes.execute(opts or {})
end

function M.structs(opts)
  cmd_structs.execute(opts or {})
end

function M.enums(opts)
  cmd_enums.execute(opts or {})
end

function M.config_grep(opts)
  cmd_config_grep.execute(opts or {})
end
function M.config_files(opts)
  cmd_config_files.execute(opts or {})
end
function M.system_open(opts)
  cmd_system_open.execute(opts or {})
end

function M.implement_virtual(opts)
  cmd_implement_virtual.execute(opts or {})
end

function M.goto_super_def(opts)
  opts = opts or {}
  opts.mode = "definition"
  cmd_goto_super.execute(opts)
end

function M.goto_super_impl(opts)
  opts = opts or {}
  opts.mode = "implementation"
  cmd_goto_super.execute(opts)
end

function M.config_tree(opts)
  cmd_config_tree.execute(opts or {})
end

function M.find_module(opts)
  cmd_find_module.execute(opts or {})
end
return M
