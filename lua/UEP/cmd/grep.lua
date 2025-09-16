-- lua/UEP/cmd/grep.lua
-- :UEP grep コマンドの実装（初期クエリなしバージョン）
local grep_core = require("UEP.cmd.core.grep")
local uep_log = require("UEP.logger")
local unl_finder = require("UNL.finder")
local uep_config = require("UEP.config")

local M = {}

---
-- コマンドビルダーから呼び出される実行関数
-- @param opts table | nil コマンド引数を含むテーブル
function M.execute(opts)
  local log = uep_log.get()
  opts = opts or {}

  -- 1. コマンド引数を解釈する
  -- command.builderの定義により、opts.categoryには "game"、"engine"、またはnilが入る
  -- 指定がなければ 'game' をデフォルト値とする
  local scope = opts.category or "game"

  -- 'category' が "game" でも "engine" でもない場合、それは引数なしと見なす
  if scope:lower() ~= "game" and scope:lower() ~= "engine" then
    scope = "game"
  end

  -- 2. 検索範囲 (search_paths) を決定する
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    return log.error("Not in an Unreal Engine project directory.")
  end

  local search_paths = {}
  local conf = uep_config.get()
  local include_dirs = conf.include_directory or { "Source", "Plugins", "Config" }

  -- Game スコープのパスを追加
  for _, dir in ipairs(include_dirs) do
    local path = vim.fs.joinpath(project_root, dir)
    if vim.fn.isdirectory(path) == 1 then
      table.insert(search_paths, path)
    end
  end

  -- Engine スコープの場合、Engineのパスも追加
  if scope == "engine" then
    local proj_info = unl_finder.project.find_project(project_root)
    local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject, { logger = log }) or nil

    if engine_root then
      for _, dir in ipairs(include_dirs) do
        local path = vim.fs.joinpath(engine_root, "Engine", dir)
        if vim.fn.isdirectory(path) == 1 then
          table.insert(search_paths, path)
        end
      end
    else
      log.warn("Could not determine engine root. Searching in project only.")
    end
  end

  -- 3. grep_core を呼び出してピッカーを起動
  -- initial_query は常に空文字にする
  grep_core.start_live_grep({
    search_paths = search_paths,
    title = string.format("Live Grep (%s)", scope),
    initial_query = "",
  })
end

return M
