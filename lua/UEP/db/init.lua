-- lua/UEP/db/init.lua
local uep_log = require("UEP.logger")
local schema = require("UEP.db.schema")
local unl_path = require("UNL.path") -- パス正規化用
local unl_cache = require("UNL.cache.core")
local uep_config = require("UEP.config")

-- kkharji/sqlite.lua をロード
local has_sqlite, sqlite = pcall(require, "sqlite")
if not has_sqlite then
  error("[UEP.db] 'kkharji/sqlite.lua' not found. Please install it.")
end

local M = {}

local db_instance = nil
local current_db_path = nil

-- DBパスの生成 (プロジェクト名 + パスハッシュ)
-- これならファイル名が短くなりつつ、ディレクトリごとのユニーク性も担保される
local function get_db_path()
  -- カレントディレクトリを正規化 (区切り文字を統一) してハッシュ化の種にする
  local cwd = unl_path.normalize(vim.loop.cwd())
  
  -- UNL.cache.core を使ってキャッシュディレクトリを取得
  local conf = uep_config.get()
  local cache_dir = unl_path.normalize(unl_cache.get_cache_dir(conf))

  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end

  local project_name = vim.fn.fnamemodify(cwd, ":t")
  -- フルパスからハッシュを生成 (ディレクトリが違えば別ファイルになる)
  local cwd_hash = vim.fn.sha256(cwd):sub(1, 8) 
  
  return string.format("%s/%s_%s.db", cache_dir, project_name, cwd_hash)
end

function M.get()
  if db_instance then return db_instance end

  local db_path = get_db_path()

  -- sqlite.new でインスタンス生成
  db_instance = sqlite.new(db_path, { keep_open = true })

  if not db_instance then
    uep_log.get().error("Failed to create sqlite object at: %s", db_path)
    return nil
  end

  local ok, err = pcall(function() 
    db_instance:open()
    db_instance:eval("PRAGMA foreign_keys = ON;")
  end)
  if not ok then
    uep_log.get().error("Failed to open DB: %s", err)
    return nil
  end

  -- 設定
  db_instance:eval("PRAGMA journal_mode = WAL;") 
  db_instance:eval("PRAGMA synchronous = NORMAL;")
  db_instance:eval("PRAGMA foreign_keys = ON;")

  -- テーブル作成
  local schema_ok, schema_err = pcall(schema.ensure_tables, db_instance)
  if not schema_ok then
    uep_log.get().error("DB Schema Error: %s", schema_err)
    db_instance:close() 
    db_instance = nil
    return nil
  end

  current_db_path = db_path
  return db_instance
end

function M.close()
  if db_instance then
    db_instance:close()
  end
  db_instance = nil
end

function M.get_path()
  return current_db_path or get_db_path()
end

-- トランザクション管理
function M.transaction(func)
  local db = M.get()
  if not db then return end

  local function insert_helper(table_name, data)
    local cols = {}
    local vals = {}
    local placeholders = {}
    for k, v in pairs(data) do
      table.insert(cols, string.format('"%s"', k))
      table.insert(vals, v)
      table.insert(placeholders, "?")
    end
    local sql = string.format("INSERT INTO %s (%s) VALUES (%s)", table_name, table.concat(cols, ", "), table.concat(placeholders, ", "))
    local res = db:eval(sql, vals)
    if res == false then error(string.format("Insert failed for table '%s'", table_name)) end
    local rows = db:eval("SELECT last_insert_rowid() as id")
    if type(rows) == "table" and rows[1] then return rows[1].id end
    return nil
  end

  local begin_res = db:eval("BEGIN IMMEDIATE TRANSACTION;")
  if begin_res == false then error("Failed to start transaction.") end
  
  local status, result_or_err = pcall(func, db, insert_helper)
  
  if status then
    local commit_res = db:eval("COMMIT;")
    if commit_res == false then error("COMMIT failed") end
    return result_or_err
  else
    pcall(function() db:eval("ROLLBACK;") end)
    error(result_or_err)
  end
end

return M
