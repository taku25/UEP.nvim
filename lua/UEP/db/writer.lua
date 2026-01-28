-- lua/UEP/db/writer.lua
local uep_db = require("UEP.db.init")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

-- ヘッダーファイル判定
local function is_header(ext)
  return ext == "h" or ext == "hpp" or ext == "ush" or ext == "usf"
end

-- ファイルパスから拡張子とファイル名を抽出
local function parse_path(full_path)
  local filename = vim.fn.fnamemodify(full_path, ":t")
  local ext = vim.fn.fnamemodify(filename, ":e")
  return filename, ext:lower()
end

-- 値のクリーンアップ (JSON null = vim.NIL を Lua nil に変換してデフォルト値を適用)
local function clean_val(val, default)
  if val == nil or val == vim.NIL then
    return default
  end
  return val
end

-- 単一のファイルパスをDBに登録し、関連するクラス情報も保存する
local function insert_file_and_classes(insert_fn, module_id, file_path, header_details)
  if not file_path then 
    uep_log.get().warn("[UEP.db] insert_file_and_classes: file_path is nil")
    return 
  end
  
  uep_log.get().trace("[UEP.db] Inserting file: %s (module_id: %s)", file_path, tostring(module_id))
  
  local filename, ext = parse_path(file_path)
  local is_hdr = is_header(ext)

  -- header_details からメタデータを取得
  local file_mtime = 0
  local file_hash = nil
  
  if header_details and header_details[file_path] then
      file_mtime = clean_val(header_details[file_path].mtime, 0)
      file_hash = clean_val(header_details[file_path].file_hash, nil)
  end

  -- 1. files テーブルへ挿入
  local file_id = insert_fn("files", {
    path = file_path,
    filename = filename,
    extension = ext,
    mtime = file_mtime,
    file_hash = file_hash,
    module_id = module_id,
    is_header = is_hdr and 1 or 0
  })

  if not file_id then
    uep_log.get().error("[UEP.db] Failed to insert file: %s", file_path)
    return
  end
  
  uep_log.get().trace("[UEP.db] Successfully inserted file: %s (file_id: %s)", filename, tostring(file_id))

  -- 2. クラス情報の挿入
  if file_id and is_hdr and header_details and header_details[file_path] then
    local info = header_details[file_path]
    if info.classes then
      for _, cls in ipairs(info.classes) do
        local class_name = clean_val(cls.name or cls.class_name, nil)
        local base_class = clean_val(cls.base_class or cls.super, "")
        local line_no = clean_val(cls.line_number or cls.line, 1)
        local sym_type = clean_val(cls.symbol_type, "class")

        if class_name and class_name ~= "" and type(class_name) == "string" then
          -- base_classes (配列) の処理
          local bases = cls.base_classes or {}
          if type(bases) ~= "table" then bases = {} end
          -- 既存の base_class 文字列があればそれを先頭に追加 (Scanner変更前の互換性)
          if cls.base_class and cls.base_class ~= "" then
              local found = false
              for _, b in ipairs(bases) do if b == cls.base_class then found = true break end end
              if not found then table.insert(bases, 1, cls.base_class) end
          end
          
                    local db_conn = uep_db.get()
                    local class_id = nil
          
                    -- 既存のクラスがあるか確認 (ファイルごとに一意)
                    local q_check = "SELECT id FROM classes WHERE name = ? AND symbol_type = ? AND file_id = ?"
                    local p_check = { class_name, sym_type, file_id }
                    if namespace then
                        q_check = q_check .. " AND namespace = ?"
                        table.insert(p_check, namespace)
                    else
                        q_check = q_check .. " AND namespace IS NULL"
                    end
                    
                    local existing_rows = db_conn:eval(q_check, p_check)
                    if type(existing_rows) == "table" and existing_rows[1] then
                        class_id = existing_rows[1].id
                        -- 既存レコードの基本情報を更新
                        db_conn:eval([[
                          UPDATE classes SET base_class = ?, file_id = ?, line_number = ? WHERE id = ?
                        ]], { primary_base, file_id, line_no, class_id })
                    else
                        -- 新規挿入
                        local status, res = pcall(insert_fn, "classes", {
                          name = class_name,
                          namespace = namespace,
                          base_class = primary_base, 
                          file_id = file_id,
                          line_number = line_no,
                          symbol_type = sym_type
                        })
                        if status then
                            -- 挿入直後のIDを取得
                            local id_rows = db_conn:eval("SELECT last_insert_rowid() as id")
                            class_id = (type(id_rows) == "table" and id_rows[1]) and id_rows[1].id or nil
                        else
                            uep_log.get().error("[UEP.db] Insert class failed for '%s' in %s: %s", class_name, file_path, tostring(res))
                        end
                    end
          
                    if class_id then
                       -- 継承情報の更新 (DELETE -> INSERT)
                       db_conn:eval("DELETE FROM inheritance WHERE child_id = ?", { class_id })             for _, parent in ipairs(bases) do
                 if parent and parent ~= "" then
                     pcall(insert_fn, "inheritance", {
                         child_id = class_id,
                         parent_name = parent
                     })
                 end
             end

             -- 3. メンバー情報の挿入 (NEW)
             db_conn:eval("DELETE FROM members WHERE class_id = ?", { class_id })
             db_conn:eval("DELETE FROM enum_values WHERE enum_id = ?", { class_id })

             if cls.members then
                 for _, mem in ipairs(cls.members) do
                 local m_type = clean_val(mem.type, "variable")
                 local m_name = clean_val(mem.name, "unknown")
                 
                 if m_type == "enum_item" then
                     -- Enum値の保存
                     pcall(insert_fn, "enum_values", {
                         enum_id = class_id,
                         name = m_name
                     })
                 else
                     -- 通常メンバーの保存
                     local m_flags = clean_val(mem.flags, "")
                     local is_static = m_flags:find("static") and 1 or 0
                     
                     local mem_status, mem_res = pcall(insert_fn, "members", {
                         name = m_name,
                         class_id = class_id,
                         type = m_type,
                         flags = m_flags,
                         access = "public",
                         detail = clean_val(mem.detail, ""), -- 追加
                         return_type = clean_val(mem.return_type, ""), -- 追加
                         is_static = is_static
                     })
                     if not mem_status then
                         uep_log.get().error("[UEP.db] Insert member failed for '%s' in class '%s': %s", m_name, class_name, tostring(mem_res))
                     end
                 end
             end
          end
        end
      end
      end
      uep_log.get().trace("[UEP.db] Inserted %d classes for header %s", #info.classes, filename)
    end
  end
end

---
-- モジュールグループを処理
local function process_module_group(insert_fn, modules_map, group_type, scope)
  if not modules_map then return end
  for mod_name, mod_data in pairs(modules_map) do
    local deep_deps_json = nil
    if mod_data.deep_dependencies and type(mod_data.deep_dependencies) == "table" then
        deep_deps_json = vim.json.encode(mod_data.deep_dependencies)
    end

    local mod_id = insert_fn("modules", {
      name = mod_name,
      type = group_type,
      scope = scope,
      root_path = (mod_data.module_root or ""):gsub("\\", "/"),
      build_cs_path = (mod_data.path or ""):gsub("\\", "/"),
      deep_dependencies = deep_deps_json
    })

    if mod_id then
      local files_map = mod_data.files
      local details = mod_data.header_details or {}
      if files_map then
        if files_map.source then
          for _, path in ipairs(files_map.source) do
            insert_file_and_classes(insert_fn, mod_id, path, details)
          end
        end
        if files_map.config then for _, path in ipairs(files_map.config) do insert_file_and_classes(insert_fn, mod_id, path, nil) end end
        if files_map.shader then for _, path in ipairs(files_map.shader) do insert_file_and_classes(insert_fn, mod_id, path, nil) end end
        if files_map.other then for _, path in ipairs(files_map.other) do insert_file_and_classes(insert_fn, mod_id, path, nil) end end
      end
    end
  end
end

---
-- 単一モジュールのファイルデータをSQLiteに保存する (Diff Update / Incremental Sync)
function M.save_module_files(module_meta, files_data, header_details, directories_data)
  if not (module_meta and module_meta.name and module_meta.module_root) then return end
  local log = uep_log.get()
  local start_t = vim.loop.hrtime()

  local success, err = pcall(function()
    uep_db.transaction(function(db, insert_fn_base)
      -- 1. モジュールID取得 / 更新 / 作成
      local rows = db:eval("SELECT id FROM modules WHERE name = ? AND root_path = ?", { module_meta.name, module_meta.module_root })
      local module_id = (type(rows) == "table" and rows[1]) and rows[1].id or nil

      if module_id then
        db:eval([[UPDATE modules SET type = ?, scope = ?, build_cs_path = ?, owner_name = ?, component_name = ?, deep_dependencies = ? WHERE id = ?]], {
          module_meta.type or "Runtime",
          module_meta.scope or "Individual",
          (module_meta.path or ""):gsub("\\", "/"),
          module_meta.owner_name,
          module_meta.component_name,
          module_meta.deep_dependencies and vim.json.encode(module_meta.deep_dependencies) or nil,
          module_id
        })
      else
        module_id = insert_fn_base("modules", {
          name = module_meta.name,
          type = module_meta.type or "Runtime",
          scope = module_meta.scope or "Individual",
          root_path = (module_meta.module_root or ""):gsub("\\", "/"),
          build_cs_path = (module_meta.path or ""):gsub("\\", "/"),
          owner_name = module_meta.owner_name,
          component_name = module_meta.component_name,
          deep_dependencies = module_meta.deep_dependencies and vim.json.encode(module_meta.deep_dependencies) or nil
        })
      end
      if not module_id then error("Failed to get module_id") end

      -- 2. 既存ファイルのマップを作成
      local existing_files_rows = db:eval("SELECT id, path FROM files WHERE module_id = ?", { module_id })
      local db_files_map = {}
      if type(existing_files_rows) == "table" then
        for _, row in ipairs(existing_files_rows) do
          db_files_map[row.path] = row.id
        end
      end

      -- 3. ディレクトリ全置換
      db:eval("DELETE FROM directories WHERE module_id = ?", { module_id })
      if directories_data then
        local seen_dirs = {}
        for category, dir_list in pairs(directories_data) do
          if type(dir_list) == "table" then
            for _, dir_path in ipairs(dir_list) do
              if dir_path and not seen_dirs[dir_path] then
                 seen_dirs[dir_path] = true
                 insert_fn_base("directories", { path = dir_path, category = category, module_id = module_id })
              end
            end
          end
        end
      end

      -- 4. ファイルの Diff Update
      local current_scan_paths = {}
      if files_data then
        for category, file_list in pairs(files_data) do
          if type(file_list) == "table" then
            for _, file_path in ipairs(file_list) do
              if file_path and not current_scan_paths[file_path] then
                current_scan_paths[file_path] = true
                if not db_files_map[file_path] then
                   local status, res = pcall(insert_file_and_classes, insert_fn_base, module_id, file_path, header_details)
                   if not status then
                       local owner_rows = db:eval("SELECT id FROM files WHERE path = ?", { file_path })
                       if type(owner_rows) == "table" and owner_rows[1] then
                            local old_id = owner_rows[1].id
                            db:eval("DELETE FROM classes WHERE file_id = ?", { old_id })
                            db:eval("DELETE FROM files WHERE id = ?", { old_id })
                            insert_file_and_classes(insert_fn_base, module_id, file_path, header_details)
                       end
                   end
                else
                   if header_details and header_details[file_path] then
                       local fid = db_files_map[file_path]
                       db:eval("DELETE FROM classes WHERE file_id = ?", { fid })
                       db:eval("DELETE FROM files WHERE id = ?", { fid })
                       insert_file_and_classes(insert_fn_base, module_id, file_path, header_details)
                   end
                end
              end
            end
          end
        end
      end

      -- 5. 削除
      for path, fid in pairs(db_files_map) do
         if not current_scan_paths[path] then
             db:eval("DELETE FROM classes WHERE file_id = ?", { fid })
             db:eval("DELETE FROM files WHERE id = ?", { fid })
         end
      end
    end)
  end)
  
  if not success then
    log.error("[UEP.db] Failed to save module '%s' to SQLite: %s", module_meta.name, tostring(err))
  end
end

-- 単一ファイルの更新
function M.update_single_file(module_name, file_path, header_data)
  local log = uep_log.get()
  local db = uep_db.get()
  local rows = db:eval("SELECT id FROM modules WHERE name = ?", { module_name })
  local module_id = (rows and rows[1]) and rows[1].id
  if not module_id then return false end

  uep_db.transaction(function(db_conn, insert_fn_base)
    local file_rows = db_conn:eval("SELECT id FROM files WHERE path = ?", { file_path })
    if type(file_rows) == "table" and file_rows[1] then
       db_conn:eval("DELETE FROM classes WHERE file_id = ?", { file_rows[1].id })
       db_conn:eval("DELETE FROM files WHERE id = ?", { file_rows[1].id })
    end
    if vim.fn.filereadable(file_path) == 1 then
       local details_map = {}
       if header_data then details_map[file_path] = header_data end
       insert_file_and_classes(insert_fn_base, module_id, file_path, details_map)
    end
  end)
  return true
end

---
-- 全プロジェクトデータをDBに保存
function M.save_project_scan(components_data)
  if not components_data then return end
  local log = uep_log.get()
  local start_t = vim.loop.hrtime()
  
  uep_db.transaction(function(db, insert_fn_base)
    db:eval("DELETE FROM components;")
    local function insert_safe(table_name, data)
      local cols, vals, placeholders = {}, {}, {}
      for k, v in pairs(data) do table.insert(cols, k); table.insert(vals, v); table.insert(placeholders, "?") end
      db:eval(string.format("INSERT OR IGNORE INTO %s (%s) VALUES (%s)", table_name, table.concat(cols, ", "), table.concat(placeholders, ", ")), vals)
      local row_id = nil
      if table_name == "modules" then
        local rows = db:eval("SELECT id FROM modules WHERE name = ? AND root_path = ?", { data.name, data.root_path })
        row_id = (type(rows) == "table" and rows[1]) and rows[1].id or nil
      else
        local rows = db:eval("SELECT last_insert_rowid() as id")
        row_id = (type(rows) == "table" and rows[1]) and rows[1].id or nil
      end
      if row_id and table_name == "modules" then
        db:eval([[UPDATE modules SET type = ?, scope = ?, build_cs_path = ?, owner_name = ?, component_name = ?, deep_dependencies = ? WHERE id = ?]], {
          data.type, data.scope, data.build_cs_path, data.owner_name, data.component_name, data.deep_dependencies, row_id
        })
      end
      return row_id
    end

    for comp_name, comp in pairs(components_data) do
      local scope = (comp.type == "Project") and "Game" or comp.type 
      insert_safe("components", {
        name = comp_name, display_name = comp.display_name or comp_name, type = comp.type,
        owner_name = comp.owner_name, root_path = comp.root_path, uplugin_path = comp.uplugin_path,
        uproject_path = comp.uproject_path, engine_association = comp.engine_association,
      })
      local function normalized_type(t, root_path)
        if (root_path or ""):lower():find("/programs/", 1, true) then return "Program" end
        return t
      end
      process_module_group(function(table_name, data)
        data.component_name = comp_name
        data.owner_name = data.owner_name or comp.owner_name
        data.type = normalized_type("Runtime", data.module_root or data.root_path)
        return insert_safe(table_name, data)
      end, comp.runtime_modules, "Runtime", scope)
      process_module_group(function(table_name, data)
        data.component_name = comp_name
        data.owner_name = data.owner_name or comp.owner_name
        data.type = normalized_type("Editor", data.module_root or data.root_path)
        return insert_safe(table_name, data)
      end, comp.editor_modules, "Editor", scope)
      process_module_group(function(table_name, data)
        data.component_name = comp_name
        data.owner_name = data.owner_name or comp.owner_name
        data.type = normalized_type("Developer", data.module_root or data.root_path)
        return insert_safe(table_name, data)
      end, comp.developer_modules, "Developer", scope)
      process_module_group(function(table_name, data)
        data.component_name = comp_name
        data.owner_name = data.owner_name or comp.owner_name
        data.type = normalized_type("Program", data.module_root or data.root_path)
        return insert_safe(table_name, data)
      end, comp.programs_modules, "Program", scope)
    end
    db:eval([[UPDATE modules SET type = 'Program' WHERE lower(root_path) LIKE '%/programs/%' OR lower(root_path) LIKE '%\programs\%']])
  end)
end

return M
