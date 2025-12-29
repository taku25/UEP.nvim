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

-- 単一のファイルパスをDBに登録し、関連するクラス情報も保存する
local function insert_file_and_classes(insert_fn, module_id, file_path, header_details)
  if not file_path then 
    uep_log.get().warn("[UEP.db] insert_file_and_classes: file_path is nil")
    return 
  end
  
  uep_log.get().trace("[UEP.db] Inserting file: %s (module_id: %s)", file_path, tostring(module_id))
  
  local filename, ext = parse_path(file_path)
  local is_hdr = is_header(ext)

  -- 1. files テーブルへ挿入
  local file_id = insert_fn("files", {
    path = file_path,
    filename = filename,
    extension = ext,
    mtime = 0,
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
        -- worker は class_name / base_class を返す。従来の name/super もサポートして両対応にする。
        local class_name = cls.name or cls.class_name
        local base_class = cls.base_class or cls.super or ""
        local line_no = cls.line_number or cls.line or 1
        local sym_type = cls.symbol_type or "class"

        if class_name and class_name ~= "" and type(class_name) == "string" then
          -- Debug logging for problematic classes
          if class_name == "None" or class_name:match("^%s*$") then
             uep_log.get().warn("[UEP.db] Suspicious class name '%s' in file %s", class_name, file_path)
          end

          local status, err = pcall(insert_fn, "classes", {
            name = class_name,
            base_class = base_class,
            file_id = file_id,
            line_number = line_no,
            symbol_type = sym_type
          })
          if not status then
             uep_log.get().error("[UEP.db] Insert class failed for '%s' in %s: %s", class_name, file_path, tostring(err))
          end
        else
          -- 無効なクラスデータをログに出力（デバッグ用）
          uep_log.get().debug("Skipping invalid class data in file %s: name=%s, type=%s", 
                              file_path, tostring(class_name), type(class_name))
        end
      end
      uep_log.get().trace("[UEP.db] Inserted %d classes for header %s", #info.classes, filename)
    end
  end
end

---
-- モジュールグループを処理
local function process_module_group(insert_fn, modules_map, group_type, scope)
  if not modules_map then 
    uep_log.get().debug("[UEP.db] process_module_group: modules_map is nil for type '%s' scope '%s'", group_type, scope)
    return 
  end
  
  local module_count = vim.tbl_count(modules_map)
  uep_log.get().debug("[UEP.db] Processing %d modules for type '%s' scope '%s'", module_count, group_type, scope)

  for mod_name, mod_data in pairs(modules_map) do
    uep_log.get().trace("[UEP.db] Inserting module: %s (%s/%s) at %s", mod_name, group_type, scope, mod_data.module_root or "unknown")
    
    -- 1. モジュール情報をINSERT
    -- schema変更により、(name, root_path) が重複しない限り登録される
    -- 同名でもパスが違えば別IDとして登録される
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

    -- 2. ファイル情報をINSERT (mod_idがあれば)
    if mod_id then
      local files_map = mod_data.files
      local details = mod_data.header_details or {}

      if files_map then
        uep_log.get().debug("[UEP.db] Module '%s' has files_map with keys: %s", mod_name, table.concat(vim.tbl_keys(files_map), ", "))
        
        if files_map.source then
          uep_log.get().debug("[UEP.db] Processing %d source files for module '%s'", #files_map.source, mod_name)
          for _, path in ipairs(files_map.source) do
            insert_file_and_classes(insert_fn, mod_id, path, details)
          end
        else
          uep_log.get().debug("[UEP.db] Module '%s' has no source files", mod_name)
        end
        
        if files_map.config then
          uep_log.get().debug("[UEP.db] Processing %d config files for module '%s'", #files_map.config, mod_name)
          for _, path in ipairs(files_map.config) do
            insert_file_and_classes(insert_fn, mod_id, path, nil)
          end
        else
          uep_log.get().debug("[UEP.db] Module '%s' has no config files", mod_name)
        end
        
        if files_map.shader then
          uep_log.get().debug("[UEP.db] Processing %d shader files for module '%s'", #files_map.shader, mod_name)
          for _, path in ipairs(files_map.shader) do
            insert_file_and_classes(insert_fn, mod_id, path, nil)
          end
        else
          uep_log.get().debug("[UEP.db] Module '%s' has no shader files", mod_name)
        end
        
        if files_map.other then
          uep_log.get().debug("[UEP.db] Processing %d other files for module '%s'", #files_map.other, mod_name)
          for _, path in ipairs(files_map.other) do
            insert_file_and_classes(insert_fn, mod_id, path, nil)
          end
        else
          uep_log.get().debug("[UEP.db] Module '%s' has no other files", mod_name)
        end
      else
        -- 一部のプラグインメタモジュールはファイルリストを持たないため情報ログに格下げ
        uep_log.get().debug("[UEP.db] Module '%s' has no files_map", mod_name)
      end
    else
      uep_log.get().error("[UEP.db] Failed to insert module '%s' - no module ID returned", mod_name)
    end
  end
end

---
-- 単一モジュールのファイルデータをSQLiteに保存する
function M.save_module_files(module_meta, files_data, header_details, directories_data)
  if not (module_meta and module_meta.name and module_meta.module_root) then
    uep_log.get().warn("save_module_files: Invalid module_meta")
    return
  end
  
  local log = uep_log.get()
  local start_t = vim.loop.hrtime()

   -- ヘッダ詳細の件数とクラス件数を計算
   local hdr_count, cls_count = 0, 0
   if header_details then
     for _, info in pairs(header_details) do
       hdr_count = hdr_count + 1
       if info.classes then cls_count = cls_count + #info.classes end
     end
   end
   if hdr_count > 0 then
     log.debug("[UEP.db] save_module_files: header_details=%d, classes=%d for '%s'", hdr_count, cls_count, module_meta.name)
   end
  
  -- エラーハンドリングを追加
  local success, err = pcall(function()
    -- トランザクション処理
    uep_db.transaction(function(db, insert_fn_base)
      -- 既存のモジュールIDを取得 (name + root_path で特定)
      local rows = db:eval("SELECT id FROM modules WHERE name = ? AND root_path = ?", { module_meta.name, module_meta.module_root })
      local module_id = (type(rows) == "table" and rows[1]) and rows[1].id or nil

      if module_id then
        -- 既存モジュールを更新
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
        -- 新規モジュールを登録
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
      
      -- モジュール内の既存ファイル・ディレクトリを全削除（削除されたファイルを反映するため）
      if module_id then
        db:eval("DELETE FROM files WHERE module_id = ?", { module_id })
        db:eval("DELETE FROM directories WHERE module_id = ?", { module_id })
      end

      if module_id and files_data then
        -- パス重複による UNIQUE(path) 衝突を避けるため、1モジュール内で重複排除してから挿入。
        -- 既存行が他モジュールにある場合は先に DELETE してから挿入する。
        local seen_paths = {}
        for category, file_list in pairs(files_data) do
          if type(file_list) == "table" then
            for _, file_path in ipairs(file_list) do
              if file_path and not seen_paths[file_path] then
                seen_paths[file_path] = true
                db:eval("DELETE FROM files WHERE path = ?", { file_path })
                insert_file_and_classes(insert_fn_base, module_id, file_path, header_details)
              end
            end
          end
        end
      end

      -- ディレクトリを登録（カテゴリ保持）
      if module_id and directories_data then
        local seen_dirs = {}
        for category, dir_list in pairs(directories_data) do
          if type(dir_list) == "table" then
            for _, dir_path in ipairs(dir_list) do
              if dir_path and not seen_dirs[dir_path] then
                seen_dirs[dir_path] = true
                -- 他モジュールからの移動を考慮してDELETE (自モジュール分は上で削除済みだが念のため)
                db:eval("DELETE FROM directories WHERE path = ?", { dir_path })
                insert_fn_base("directories", {
                  path = dir_path,
                  category = category,
                  module_id = module_id,
                })
              end
            end
          end
        end
      end
    end)
  end)
  
  if not success then
    log.error("[UEP.db] Failed to save module '%s' to SQLite: %s", module_meta.name, tostring(err))
    return
  end
  
  local ms = (vim.loop.hrtime() - start_t) / 1e6
  log.trace("[UEP.db] Saved module '%s' files to DB in %.2f ms.", module_meta.name, ms)
end

---
-- 全プロジェクトデータをDBに保存
function M.save_project_scan(components_data)
  if not components_data then 
    uep_log.get().warn("[UEP.db] save_project_scan: components_data is nil")
    return 
  end
  
  local log = uep_log.get()
  local start_t = vim.loop.hrtime()
  
  -- 入力データの詳細をログ出力
  local comp_count = 0
  local total_modules = 0
  for comp_name, comp_data in pairs(components_data) do
    comp_count = comp_count + 1
    local runtime_count = comp_data.runtime_modules and vim.tbl_count(comp_data.runtime_modules) or 0
    local editor_count = comp_data.editor_modules and vim.tbl_count(comp_data.editor_modules) or 0
    local dev_count = comp_data.developer_modules and vim.tbl_count(comp_data.developer_modules) or 0
    local prog_count = comp_data.programs_modules and vim.tbl_count(comp_data.programs_modules) or 0
    local comp_total = runtime_count + editor_count + dev_count + prog_count
    total_modules = total_modules + comp_total
    
    log.debug("[UEP.db] Component '%s' (%s): %d runtime, %d editor, %d dev, %d program = %d total modules", 
              comp_name, comp_data.type or "unknown", runtime_count, editor_count, dev_count, prog_count, comp_total)
  end
  
  log.debug("[UEP.db] Processing %d components with %d total modules...", comp_count, total_modules)

  -- トランザクション処理
  uep_db.transaction(function(db, insert_fn_base)
    -- コンポーネントは一旦全削除してから再登録（数が少なく整合性重視）
    db:eval("DELETE FROM components;")

    -- INSERT OR REPLACE を使用して上書き
    local function insert_safe(table_name, data)
      local cols = {}
      local vals = {}
      local placeholders = {}
      for k, v in pairs(data) do
        table.insert(cols, k)
        table.insert(vals, v)
        table.insert(placeholders, "?")
      end
      -- IGNOREで既存行を保持し、あとで必要なカラムだけUPDATEする
      local sql = string.format("INSERT OR IGNORE INTO %s (%s) VALUES (%s)", table_name, table.concat(cols, ", "), table.concat(placeholders, ", "))
      db:eval(sql, vals)

      -- 既存行のIDを取得
      local row_id = nil
      if table_name == "modules" then
        local rows = db:eval("SELECT id FROM modules WHERE name = ? AND root_path = ?", { data.name, data.root_path })
        row_id = (type(rows) == "table" and rows[1]) and rows[1].id or nil
      else
        local rows = db:eval("SELECT last_insert_rowid() as id")
        row_id = (type(rows) == "table" and rows[1]) and rows[1].id or nil
      end

      -- modulesテーブルの場合のみ、type/scope/build_cs_path/owner_name/component_name/deep_dependencies を更新
      if row_id and table_name == "modules" then
        db:eval([[UPDATE modules SET type = ?, scope = ?, build_cs_path = ?, owner_name = ?, component_name = ?, deep_dependencies = ? WHERE id = ?]], {
          data.type, data.scope, data.build_cs_path, data.owner_name, data.component_name, data.deep_dependencies, row_id
        })
      end

      return row_id
    end

    -- components_data をループし、componentsテーブルとmodulesを登録
    for comp_name, comp in pairs(components_data) do
      local scope = comp.type 
      if scope == "Project" then scope = "Game" end 

      insert_safe("components", {
        name = comp_name,
        display_name = comp.display_name or comp_name,
        type = comp.type,
        owner_name = comp.owner_name,
        root_path = comp.root_path,
        uplugin_path = comp.uplugin_path,
        uproject_path = comp.uproject_path,
        engine_association = comp.engine_association,
      })

      -- モジュール登録（component_name/owner_nameを付与）
      local function normalized_type(t, root_path)
        local lower_root = (root_path or ""):gsub("\\", "/"):lower()
        if lower_root:find("/programs/", 1, true) then
          return "Program"
        end
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

    -- pathベースの最終補正: /programs/ を含むものは Program として揃える
    -- Windowsパス(\)とUnixパス(/)の両方に対応
    db:eval([[UPDATE modules SET type = 'Program' WHERE lower(root_path) LIKE '%/programs/%' OR lower(root_path) LIKE '%\programs\%']])
  end)

  local ms = (vim.loop.hrtime() - start_t) / 1e6
  log.debug("[UEP.db] Saved project data to DB in %.2f ms.", ms)
end

return M
