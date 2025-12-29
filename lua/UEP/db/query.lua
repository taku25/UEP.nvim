-- lua/UEP/db/query.lua
local M = {}

-- 指定したクラスを継承しているクラスを全て取得
function M.find_derived_classes(db, base_class_name)
  local sql = [[
    SELECT c.name, c.base_class, f.path, m.name as module_name
    FROM classes c
    JOIN files f ON c.file_id = f.id
    JOIN modules m ON f.module_id = m.id
    WHERE c.base_class = ?
  ]]
  
  -- プリペアドステートメントの使用を推奨（ライブラリによる）
  return db:select(sql, { base_class_name })
end

-- ファイル名であいまい検索（Telescopeなどのソース用）
function M.search_files(db, filename_part)
  local sql = [[
    SELECT path, filename FROM files 
    WHERE filename LIKE ? 
    LIMIT 100
  ]]
  return db:select(sql, { "%" .. filename_part .. "%" })
end

-- コンポーネント名からモジュール構造を取得（project_cache.loadの代替）
function M.load_component_data(db, component_name)
  local modules_sql = [[
    SELECT m.id, m.name, m.type, m.scope, m.root_path, m.build_cs_path
    FROM modules m
    WHERE m.scope = ? OR m.scope LIKE ?
  ]]
  
  local files_sql = [[
    SELECT f.id, f.path, f.filename, f.extension, f.is_header, f.module_id
    FROM files f
    WHERE f.module_id = ?
  ]]
  
  local classes_sql = [[
    SELECT c.name, c.base_class, c.line_number
    FROM classes c
    WHERE c.file_id = ?
  ]]
  
  -- コンポーネント名でモジュールを検索（Game scope or component_name%）
  local modules = db:eval(modules_sql, { component_name, component_name .. "%" })
  if not modules then return nil end
  
  local result = {
    runtime_modules = {},
    editor_modules = {},
    developer_modules = {},
    programs_modules = {}
  }
  
  for _, mod_row in ipairs(modules) do
    -- ファイルを取得
    local files = db:eval(files_sql, { mod_row.id }) or {}
    local mod_data = {
      name = mod_row.name,
      module_root = mod_row.root_path,
      path = mod_row.build_cs_path,
      files = { source = {}, config = {}, shader = {}, other = {} },
      header_details = {}
    }
    
    for _, file_row in ipairs(files) do
      local ext = file_row.extension
      local file_path = file_row.path
      
      if ext == "cpp" or ext == "c" or ext == "cc" or ext == "h" or ext == "hpp" then
        table.insert(mod_data.files.source, file_path)
        
        -- ヘッダーファイルの場合、クラス情報を取得
        if file_row.is_header == 1 then
          local classes = db:eval(classes_sql, { file_row.id }) or {}
          local class_list = {}
          for _, cls_row in ipairs(classes) do
            table.insert(class_list, {
              name = cls_row.name,
              base_class = cls_row.base_class,
              line_number = cls_row.line_number
            })
          end
          if #class_list > 0 then
            mod_data.header_details[file_path] = { classes = class_list }
          end
        end
      elseif ext == "ini" then
        table.insert(mod_data.files.config, file_path)
      elseif ext == "usf" or ext == "ush" then
        table.insert(mod_data.files.shader, file_path)
      else
        table.insert(mod_data.files.other, file_path)
      end
    end
    
    -- モジュールタイプに応じて分類
    if mod_row.type == "Runtime" then
      result.runtime_modules[mod_row.name] = mod_data
    elseif mod_row.type == "Editor" then
      result.editor_modules[mod_row.name] = mod_data
    elseif mod_row.type == "Developer" then
      result.developer_modules[mod_row.name] = mod_data
    elseif mod_row.type == "Program" then
      result.programs_modules[mod_row.name] = mod_data
    end
  end
  
  return result
end

-- 特定のモジュール名のデータを取得
function M.get_module_by_name(db, module_name)
  local sql = [[
    SELECT m.id, m.name, m.type, m.scope, m.root_path, m.build_cs_path
    FROM modules m
    WHERE m.name = ?
    LIMIT 1
  ]]
  
  local modules = db:eval(sql, { module_name })
  if not modules or #modules == 0 then return nil end
  
  local mod_row = modules[1]
  local files_sql = [[
    SELECT f.path, f.filename, f.extension, f.is_header
    FROM files f
    WHERE f.module_id = ?
  ]]
  
  local files = db:eval(files_sql, { mod_row.id }) or {}
  local mod_data = {
    name = mod_row.name,
    module_root = mod_row.root_path,
    path = mod_row.build_cs_path,
    files = { source = {}, config = {}, shader = {}, other = {} }
  }
  
  for _, file_row in ipairs(files) do
    local ext = file_row.extension
    local file_path = file_row.path
    
    if ext == "cpp" or ext == "c" or ext == "cc" or ext == "h" or ext == "hpp" then
      table.insert(mod_data.files.source, file_path)
    elseif ext == "ini" then
      table.insert(mod_data.files.config, file_path)
    elseif ext == "usf" or ext == "ush" then
      table.insert(mod_data.files.shader, file_path)
    else
      table.insert(mod_data.files.other, file_path)
    end
  end
  
  return mod_data
end

-- モジュール名リストからクラスを取得（チャンク処理付き）
function M.get_classes_in_modules(db, module_names)
  if not module_names or #module_names == 0 then return {} end
  
  local chunk_size = 900
  local all_results = {}
  
  for i = 1, #module_names, chunk_size do
    local chunk = {}
    for j = i, math.min(i + chunk_size - 1, #module_names) do
      table.insert(chunk, module_names[j])
    end
    
    local placeholders = {}
    for _ in ipairs(chunk) do table.insert(placeholders, "?") end
    
    local sql = string.format([[
      SELECT c.name as class_name, c.base_class, c.line_number, f.path as file_path, f.filename, c.symbol_type
      FROM classes c
      JOIN files f ON c.file_id = f.id
      JOIN modules m ON f.module_id = m.id
      WHERE m.name IN (%s)
    ]], table.concat(placeholders, ","))
    
    local rows = db:eval(sql, chunk)
    if rows then
      for _, row in ipairs(rows) do table.insert(all_results, row) end
    end
  end
  
  return all_results
end

-- 再帰的に派生クラスを取得 (CTE使用)
function M.get_recursive_derived_classes(db, base_class_name)
  local sql = [[
    WITH RECURSIVE derived_cte AS (
      SELECT name, base_class, file_id, line_number, symbol_type
      FROM classes
      WHERE base_class = ?
      UNION ALL
      SELECT c.name, c.base_class, c.file_id, c.line_number, c.symbol_type
      FROM classes c
      JOIN derived_cte p ON c.base_class = p.name
    )
    SELECT d.name as class_name, d.base_class, d.line_number, f.path as file_path, f.filename, d.symbol_type, m.name as module_name
    FROM derived_cte d
    JOIN files f ON d.file_id = f.id
    JOIN modules m ON f.module_id = m.id
  ]]
  return db:eval(sql, { base_class_name })
end

-- 再帰的に親クラス(継承チェーン)を取得 (CTE使用)
function M.get_recursive_parent_classes(db, child_class_name)
  local sql = [[
    WITH RECURSIVE parents_cte AS (
      SELECT name, base_class, file_id, line_number, symbol_type, 0 as level
      FROM classes
      WHERE name = ?
      UNION ALL
      SELECT c.name, c.base_class, c.file_id, c.line_number, c.symbol_type, p.level + 1
      FROM classes c
      JOIN parents_cte p ON p.base_class = c.name
    )
    SELECT d.name as class_name, d.base_class, d.line_number, f.path as file_path, f.filename, d.symbol_type, m.name as module_name
    FROM parents_cte d
    JOIN files f ON d.file_id = f.id
    JOIN modules m ON f.module_id = m.id
    ORDER BY level ASC
  ]]
  return db:eval(sql, { child_class_name })
end

-- プログラムモジュールのファイルを取得
function M.get_program_files(db)
  local sql = [[
    SELECT f.path, m.name as module_name, m.root_path as module_root
    FROM files f
    JOIN modules m ON f.module_id = m.id
    WHERE m.type = 'Program'
  ]]
  return db:eval(sql)
end

-- 全てのINIファイルを取得 (モジュール内)
function M.get_all_ini_files(db)
  local sql = [[
    SELECT f.path, m.name as module_name, m.root_path as module_root
    FROM files f
    JOIN modules m ON f.module_id = m.id
    WHERE f.extension = 'ini'
  ]]
  return db:eval(sql)
end

-- 特定のモジュール内でシンボルを検索
function M.find_symbol_in_module(db, module_name, symbol_name)
  local sql = [[
    SELECT f.path as file_path, c.line_number
    FROM classes c
    JOIN files f ON c.file_id = f.id
    JOIN modules m ON f.module_id = m.id
    WHERE m.name = ? AND c.name = ?
    LIMIT 1
  ]]
  local rows = db:eval(sql, { module_name, symbol_name })
  if rows and #rows > 0 then
    return rows[1]
  end
  return nil
end

-- クラス名でクラス情報を検索 (完全一致)
function M.find_class_by_name(db, class_name)
  local sql = [[
    SELECT c.name as class_name, c.base_class, c.line_number, f.path as file_path, f.filename, c.symbol_type, m.name as module_name, m.root_path as module_root
    FROM classes c
    JOIN files f ON c.file_id = f.id
    JOIN modules m ON f.module_id = m.id
    WHERE c.name = ?
    LIMIT 1
  ]]
  local rows = db:eval(sql, { class_name })
  if rows and #rows > 0 then
    return rows[1]
  end
  return nil
end

-- パスの一部でファイルを検索 (open_file フォールバック用)
function M.search_files_by_path_part(db, partial_path)
  -- partial_path は / 区切りであることを想定
  -- SQLite の LIKE は大文字小文字を区別しない (デフォルト設定の場合)
  local sql = [[
    SELECT f.path, f.filename, m.root_path as module_root
    FROM files f
    JOIN modules m ON f.module_id = m.id
    WHERE f.path LIKE ?
    LIMIT 50
  ]]
  -- パスのどこかに含まれるか
  return db:eval(sql, { "%" .. partial_path .. "%" })
end

return M
