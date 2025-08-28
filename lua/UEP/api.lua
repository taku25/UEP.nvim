-- lua/UEP/api.lua (薄いAPI層として修正)

local cmd_refresh = require("UEP.cmd.refresh")
local cmd_cd = require("UEP.cmd.cd")
local cmd_delete = require("UEP.cmd.delete")
local cmd_reload_config = require("UEP.cmd.reload_config")
local cmd_files = require("UEP.cmd.files")
local cmd_module_files = require("UEP.cmd.module_files")
local cmd_module_tree = require("UEP.cmd.module_tree")
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


function M.module_tree(opts)
  cmd_module_tree.execute(opts or {})
end

function M.tree(opts)
  cmd_tree.execute(opts or {})
end

function M.get_project_info()
  -- UNLのfinderを使って、現在のディレクトリからプロジェクトルートを探す
  local unl_finder = require("UNL.finder")
  local project_root = unl_finder.project.find_project_root(vim.fn.getcwd())
  
  if not project_root then
    -- プロジェクトが見つからなければ nil を返す
    return nil
  end

  -- .uproject ファイルのキャッシュをロードして、より詳細な情報を取得することもできるが、
  -- まずはファイル名からプロジェクト名を取得するシンプルな方法で実装する。
  local uproject_path = unl_finder.project.find_project_file(project_root)
  local project_name = vim.fn.fnamemodify(uproject_path, ":t:r") -- ファイル名から拡張子を除いた部分

  return {
    name = project_name,
    root = project_root,
  }
end
return M
