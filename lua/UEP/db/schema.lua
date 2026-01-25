-- lua/UEP/db/schema.lua
local M = {}

local function ensure_column(db, table_name, column_name, column_def)
  local info = db:eval(string.format("PRAGMA table_info(%s)", table_name))
  local exists = false
  if info then
    for _, col in ipairs(info) do
      if col.name == column_name then exists = true break end
    end
  end
  if not exists then
    db:eval(string.format("ALTER TABLE %s ADD COLUMN %s", table_name, column_def))
  end
end

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
      owner_name TEXT,
      component_name TEXT,
      UNIQUE(name, root_path)
    );
  ]])
  
  -- 既存テーブルに不足列があれば追加
  ensure_column(db, "modules", "owner_name", "owner_name TEXT")
  ensure_column(db, "modules", "component_name", "component_name TEXT")
  ensure_column(db, "modules", "deep_dependencies", "deep_dependencies TEXT")
  
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

  -- file_hash カラムを追加 (インクリメンタル更新用)
  ensure_column(db, "files", "file_hash", "file_hash TEXT")

  -- 2b. Directories Table
  db:eval([[
    CREATE TABLE IF NOT EXISTS directories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT NOT NULL,
      category TEXT,
      module_id INTEGER,
      UNIQUE(path, module_id),
      FOREIGN KEY(module_id) REFERENCES modules(id) ON DELETE CASCADE
    );
  ]])

  db:eval("CREATE INDEX IF NOT EXISTS idx_directories_module_id ON directories(module_id);")
  db:eval("CREATE INDEX IF NOT EXISTS idx_directories_path ON directories(path);")

  -- 3. Components Table
  db:eval([[
    CREATE TABLE IF NOT EXISTS components (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      display_name TEXT,
      type TEXT,
      owner_name TEXT,
      root_path TEXT,
      uplugin_path TEXT,
      uproject_path TEXT,
      engine_association TEXT
    );
  ]])

  db:eval("CREATE INDEX IF NOT EXISTS idx_components_type ON components(type);")
  db:eval("CREATE INDEX IF NOT EXISTS idx_components_owner ON components(owner_name);")

  -- 4. Project Meta Table
  db:eval([[
    CREATE TABLE IF NOT EXISTS project_meta (
      key TEXT PRIMARY KEY,
      value TEXT
    );
  ]])

  -- 3. Classes Table
  db:eval([[
    CREATE TABLE IF NOT EXISTS classes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      namespace TEXT, -- 名前空間 (NEW)
      base_class TEXT,
      file_id INTEGER,
      line_number INTEGER,
      FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
    );
  ]])

  -- クラス検索用インデックス
  db:eval("CREATE INDEX IF NOT EXISTS idx_classes_name ON classes(name);")
  db:eval("CREATE INDEX IF NOT EXISTS idx_classes_base_class ON classes(base_class);")
  
  -- symbol_type カラムを追加 (class, struct, enum)
  ensure_column(db, "classes", "symbol_type", "symbol_type TEXT DEFAULT 'class'")
  -- namespace カラムを追加
  ensure_column(db, "classes", "namespace", "namespace TEXT")
  
  -- 重複防止のためのユニーク制約を追加
  db:eval("CREATE UNIQUE INDEX IF NOT EXISTS idx_classes_unique_name_type ON classes(name, symbol_type, namespace)")

  -- 4. Members Table (NEW)
  -- クラス/構造体のメンバー（関数、変数、プロパティ）を格納
  db:eval([[
    CREATE TABLE IF NOT EXISTS members (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      class_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL, -- 'function' or 'property' or 'enum_item'
      flags TEXT,         -- 'static', 'virtual', 'UFUNCTION', etc.
      access TEXT,        -- 'public', 'protected', 'private'
      detail TEXT,        -- 引数リストや型詳細 (NEW)
      return_type TEXT,   -- 戻り値の型 (NEW)
      is_static INTEGER,
      FOREIGN KEY(class_id) REFERENCES classes(id) ON DELETE CASCADE
    );
  ]])

  -- メンバー検索用インデックス
  db:eval("CREATE INDEX IF NOT EXISTS idx_members_name ON members(name);")
  db:eval("CREATE INDEX IF NOT EXISTS idx_members_class_id ON members(class_id);")

  -- 5. Enum Values Table (NEW)
  -- Enumの各要素を格納
  db:eval([[
    CREATE TABLE IF NOT EXISTS enum_values (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      enum_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      FOREIGN KEY(enum_id) REFERENCES classes(id) ON DELETE CASCADE
    );
  ]])

  db:eval("CREATE INDEX IF NOT EXISTS idx_enum_values_id ON enum_values(enum_id);")

  -- 6. Inheritance Table (NEW - 多重継承対応)
  db:eval([[
    CREATE TABLE IF NOT EXISTS inheritance (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      child_id INTEGER NOT NULL,
      parent_name TEXT NOT NULL,
      FOREIGN KEY(child_id) REFERENCES classes(id) ON DELETE CASCADE
    );
  ]])
  db:eval("CREATE INDEX IF NOT EXISTS idx_inheritance_child ON inheritance(child_id);")
  db:eval("CREATE INDEX IF NOT EXISTS idx_inheritance_parent ON inheritance(parent_name);")
end

return M
