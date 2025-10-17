-- lua/UEP/cmd/program_grep.lua

local grep_core = require("UEP.cmd.core.grep")
local unl_finder = require("UNL.finder")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local uep_config = require("UEP.config")

local M = {}

---
-- プロジェクトとエンジン内の固定された'Programs'ディレクトリを対象にLive Grepを実行します。
function M.execute(opts)
  local log = uep_log.get()

  -- STEP 1: プロジェクトルートを特定
  local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then
    return log.error("program_grep: Unreal Engineのプロジェクト内ではありません。")
  end

  -- STEP 2: エンジンルートを特定（見つからなくても処理は続行）
  local proj_info = unl_finder.project.find_project(project_root)
  local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject,
    {
      engine_override_path = uep_config.get().engine_path,
    })

  -- STEP 3: 検索対象となる固定パスのリストを作成
  local potential_paths = {
    fs.joinpath(project_root, "Programs"),
    fs.joinpath(project_root, "Source", "Programs"),
  }

  if engine_root then
    table.insert(potential_paths, fs.joinpath(engine_root, "Engine", "Programs"))
    table.insert(potential_paths, fs.joinpath(engine_root, "Engine", "Source", "Programs"))
  end

  -- STEP 4: 実際に存在するディレクトリのみを検索パスとして確定させる
  local search_paths = {}
  for _, path in ipairs(potential_paths) do
    if vim.fn.isdirectory(path) == 1 then
      table.insert(search_paths, path)
    end
  end

  if #search_paths == 0 then
    return log.warn("検索対象となる'Programs'ディレクトリが見つかりませんでした。")
  end

  log.info("Starting grep in %d 'Programs' directories.", #search_paths)

  -- STEP 5: 確定した検索パスをコアのgrepエンジンに渡して実行
  grep_core.start_live_grep({
    search_paths = search_paths,
    title = "Live Grep (Programs)",
    initial_query = "",
  })
end

return M
