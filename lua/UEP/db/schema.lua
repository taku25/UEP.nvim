-- lua/UEP/db/schema.lua
local M = {}

function M.ensure_tables(db)
  -- 1. Modules Table
  -- name のみの UNIQUE 制約を外し、(name, root_path) の複合ユニークにする
  db:eval([[
    CREATE TABLE IF NOT EXISTS modules (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      type TEXT,
      scope TEXT,
      root_path TEXT NOT NULL,
      build_cs_path TEXT,
      UNIQUE(name, root_path)
    );
  ]])
  
  -- 検索用インデックス (名前検索を高速化)
  db:eval("CREATE INDEX IF NOT EXISTS idx_modules_name ON modules(name);")

  -- 2. Files Table
  db:eval([[
    CREATE TABLE IF NOT EXISTS files (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT NOT NULL UNIQUE,
      filename TEXT NOT NULL,
      extension TEXT,
      mtime INTEGER,
      module_id INTEGER,
      is_header INTEGER DEFAULT 0,
      FOREIGN KEY(module_id) REFERENCES modules(id) ON DELETE CASCADE
    );
  ]])
  
  -- ファイル検索用インデックス
  db:eval("CREATE INDEX IF NOT EXISTS idx_files_filename ON files(filename);")
  db:eval("CREATE INDEX IF NOT EXISTS idx_files_module_id ON files(module_id);")

  -- 3. Classes Table
  db:eval([[
    CREATE TABLE IF NOT EXISTS classes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      base_class TEXT,
      file_id INTEGER,
      line_number INTEGER,
      FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
    );
  ]])

  -- クラス検索用インデックス
  db:eval("CREATE INDEX IF NOT EXISTS idx_classes_name ON classes(name);")
  db:eval("CREATE INDEX IF NOT EXISTS idx_classes_base_class ON classes(base_class);")
  
  return true
end

return M
