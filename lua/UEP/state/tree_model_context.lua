-- lua/UEP/state/tree_model_context.lua
-- :UEP tree コマンドの最後の引数（コンテキスト）を、UNL.context を使って
-- プロジェクトごとに永続的に管理します。

local unl_context = require("UNL.context")
local unl_finder = require("UNL.finder")
local log = require("UEP.logger").get()

-- UNL.context で使用する名前空間とデータキーを定義
local NAMESPACE = "UEP"
local DATA_KEY = "last_tree_args"

---
-- 現在のプロジェクトのコンテキストハンドルを取得するヘルパー関数
-- @return KeyHandle|nil 現在のプロジェクトのハンドル、またはプロジェクト外の場合はnil
local function get_project_context_handle()
  -- 1. 現在のプロジェクトルートパスを取得
  local project_root = unl_finder.project.find_project_root(vim.fn.getcwd())
  if not project_root then
    return nil -- プロジェクト内にいない場合は nil を返す
  end

  -- 2. "UEP" 名前空間を使い、現在のプロジェクトルートをキーとしてハンドルを取得
  return unl_context.use(NAMESPACE):key(project_root)
end

local M = {}

---
-- 現在のプロジェクトに対して、最後に使用された引数を保存する
-- @param args table 保存する引数のテーブル (例: { filter_query = ... })
function M.set_last_args(args)
  local handle = get_project_context_handle()
  if not handle then
    log.warn("Could not set last tree args: Not in an Unreal Engine project.")
    return
  end

  log.debug("Saving last tree args for current project via UNL.context.")
  -- "last_tree_args" というキーで、引数テーブルを保存
  handle:set(DATA_KEY, args)
end

---
-- 現在のプロジェクトから、最後に使用された引数を取得する
-- @return table|nil 保存されていた引数のテーブル、または存在しない場合はnil
function M.get_last_args()
  local handle = get_project_context_handle()
  if not handle then
    log.warn("Could not get last tree args: Not in an Unreal Engine project.")
    return nil
  end

  log.debug("Getting last tree args for current project from UNL.context.")
  -- "last_tree_args" というキーで保存された値を取得
  return handle:get(DATA_KEY)
end

return M
