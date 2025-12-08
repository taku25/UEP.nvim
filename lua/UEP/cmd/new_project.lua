local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local unl_engine_installed = require("UNL.finder.engine_installed")
local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")

local M = {}

-- エンジンのTemplatesフォルダからテンプレート一覧を取得
local function find_templates(engine_root)
  local templates_dir = fs.joinpath(engine_root, "Templates")
  local items = {}
  
  if vim.fn.isdirectory(templates_dir) == 0 then return {} end

  local handle = vim.loop.fs_scandir(templates_dir)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then break end
      
      -- TP_ で始まり、かつSourceフォルダを持つディレクトリのみ対象
      if type == "directory" and name:sub(1,3) == "TP_" then
         local full_path = fs.joinpath(templates_dir, name)
         local source_path = fs.joinpath(full_path, "Source")
         
         if vim.fn.isdirectory(source_path) == 1 then
             table.insert(items, {
                 name = name,
                 path = full_path,
                 display = name .. " (C++)",
                 filename = full_path,
                 value = { name = name, path = full_path }
             })
         end
      end
    end
  end
  return items
end

-- ★追加: バイナリファイルを安全にコピーする関数
local function raw_copy_file(src, dest)
    local inp = io.open(src, "rb")
    if not inp then return false end
    
    local data = inp:read("*a") -- 全て読み込む
    inp:close()
    
    local out = io.open(dest, "wb")
    if not out then return false end
    
    out:write(data)
    out:close()
    return true
end

-- ディレクトリを再帰的にコピーしつつ、文字列置換を行う
local function copy_template_recursive(src, dest, old_name, new_name)
  vim.fn.mkdir(dest, "p")

  local handle = vim.loop.fs_scandir(src)
  if not handle then return end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end

    if name ~= ".vs" and name ~= "Binaries" and name ~= "Intermediate" and name ~= "Saved" and name ~= ".git" then
        local src_path = fs.joinpath(src, name)
        
        local dest_name = name:gsub(old_name, new_name)
        local dest_path = fs.joinpath(dest, dest_name)

        if type == "directory" then
            copy_template_recursive(src_path, dest_path, old_name, new_name)
        elseif type == "file" then
            
            -- ★修正: テキストファイルかどうかを判定
            -- 置換対象の拡張子リスト
            local is_text_file = false
            if name:match("%.cpp$") or name:match("%.h$") or name:match("%.cs$") or name:match("%.uproject$") or name:match("%.ini$") then
                is_text_file = true
            end
            
            if is_text_file then
                -- テキストファイル: 読み込んで置換して書き込み
                local content = table.concat(vim.fn.readfile(src_path, "b"), "\n")
                
                content = content:gsub(old_name, new_name)
                content = content:gsub(old_name:upper(), new_name:upper())
                
                local f = io.open(dest_path, "wb") -- 改行コード維持のため wb
                if f then
                    f:write(content)
                    f:close()
                end
            else
                -- ★バイナリファイル (.umap, .uasset, .png etc): そのままコピー
                -- vim.loop.fs_copyfile はバージョン依存があるため、LuaのIOでコピーする
                raw_copy_file(src_path, dest_path)
            end
        end
    end
  end
end

-- (execute 関数は変更なし)
-- 以下、前回の execute と同じ内容

function M.execute(opts)
  -- ... (省略なしでそのまま) ...
  local conf = uep_config.get()
  local log = uep_log.get()

  -- 1. エンジン選択
  local engines = unl_engine_installed.find()
  if #engines == 0 then 
      log.error("No installed engines found via registry.")
      return 
  end

  local engine_items = {}
  for _, e in ipairs(engines) do
      table.insert(engine_items, { 
          display = string.format("%-20s (%s)", e.label, e.path), 
          value = e, 
          ordinal = e.version 
      })
  end

  unl_picker.pick({
    kind = "uep_new_project_engine",
    title = "Select Engine for New Project",
    items = engine_items,
    conf = conf,
    preview_enabled = false,
    on_submit = function(sel_engine)
        if not sel_engine then return end
        
        local engine_info = (type(sel_engine) == "table" and sel_engine.value) or sel_engine
        
        local engine_root
        local engine_assoc

        if type(engine_info) == "table" and engine_info.path then
            engine_root = engine_info.path
            engine_assoc = engine_info.version 
        else
            engine_root = engine_info
            engine_assoc = engine_info
        end

        if not engine_root then
             log.error("Invalid engine selection.")
             return
        end

        -- 2. テンプレート選択
        local templates = find_templates(engine_root)
        if #templates == 0 then 
            log.warn("No C++ templates found in " .. engine_root)
            return 
        end

        unl_picker.pick({
            kind = "uep_new_project_template",
            title = "Select Template",
            items = templates,
            conf = conf,
            format = function(item) return item.display end,
            preview_enabled = false,
            on_submit = function(sel_template)
                if not sel_template then return end
                
                local tpl = (type(sel_template) == "table" and sel_template.value) or sel_template
                if not tpl then tpl = sel_template end

                -- 3. プロジェクト名入力
                vim.ui.input({ prompt = "New Project Name: " }, function(project_name)
                    if not project_name or project_name == "" then return end
                    
                    if project_name:match("%s") then
                        log.error("Project name cannot contain spaces.")
                        return
                    end

                    local cwd = vim.loop.cwd()
                    local target_dir = fs.joinpath(cwd, project_name)
                    
                    if vim.fn.isdirectory(target_dir) == 1 then
                        log.error("Directory already exists: " .. target_dir)
                        return
                    end

                    log.info("Creating project '" .. project_name .. "'...")
                    
                    vim.schedule(function()
                        copy_template_recursive(tpl.path, target_dir, tpl.name, project_name)
                        
                        local uproject_file = fs.joinpath(target_dir, project_name .. ".uproject")
                        if vim.fn.filereadable(uproject_file) == 1 then
                            local content = table.concat(vim.fn.readfile(uproject_file), "\n")
                            local safe_assoc = engine_assoc:gsub("\\", "\\\\")

                            if content:match('"EngineAssociation":') then
                                content = content:gsub('"EngineAssociation":%s*".-"', '"EngineAssociation": "' .. safe_assoc .. '"')
                            else
                                content = content:gsub('{', '{\n\t"EngineAssociation": "' .. safe_assoc .. '",', 1)
                            end
                            
                            local f = io.open(uproject_file, "w")
                            if f then f:write(content); f:close() end
                        end

                        log.info("Project created at: " .. target_dir)
                        log.info("Created new project '%s' using engine '%s' (%s)", project_name, engine_root, engine_assoc)
                        
                        local choice = vim.fn.confirm("Project created. Change directory to it?", "&Yes\n&No", 1)
                        if choice == 1 then
                            vim.api.nvim_set_current_dir(target_dir)
                        end
                        -- 完了イベント
                        unl_events.publish(unl_event_types.ON_AFTER_NEW_PROJECT, {
                            project_name = project_name,
                            project_root = target_dir,
                            engine_root = engine_root,
                            engine_version = engine_assoc,
                            template = tpl.name
                        })
                        
                    end)
                end)
            end
        })
    end
  })
end

return M
