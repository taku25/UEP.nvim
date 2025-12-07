local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local unl_engine_installed = require("UNL.finder.engine_installed")

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
      if type == "directory" and name:sub(1,3) == "TP_" then
         local full_path = fs.joinpath(templates_dir, name)
         table.insert(items, {
             name = name,
             path = full_path,
             display = name,
             -- ★修正: Telescopeがプレビュー時に文字列のパスを参照できるように filename を設定
             filename = full_path,
             -- ★修正: on_submit に渡すためのデータを value に明示的に設定
             value = { name = name, path = full_path }
         })
      end
    end
  end
  return items
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
            local content = table.concat(vim.fn.readfile(src_path, "b"), "\n")
            
            if name:match("%.cpp$") or name:match("%.h$") or name:match("%.cs$") or name:match("%.uproject$") or name:match("%.ini$") then
                content = content:gsub(old_name, new_name)
                content = content:gsub(old_name:upper(), new_name:upper())
            end
            
            local f = io.open(dest_path, "wb")
            if f then
                f:write(content)
                f:close()
            end
        end
    end
  end
end

-- メイン処理
function M.execute(opts)
  local conf = uep_config.get()
  local log = uep_log.get()

  -- 1. エンジン選択
  local engines = unl_engine_installed.find()
  if #engines == 0 then 
      vim.notify("No installed engines found via registry.", vim.log.levels.ERROR)
      return 
  end

  local engine_items = {}
  for _, e in ipairs(engines) do
      table.insert(engine_items, { display = string.format("%-20s (%s)", e.label, e.path), value = e.path, ordinal = e.version })
  end

  unl_picker.pick({
    kind = "uep_new_project_engine",
    title = "Select Engine for New Project",
    items = engine_items,
    conf = conf,
    preview_enabled = false,
    on_submit = function(sel_engine)
        if not sel_engine then return end
        
        -- valueを取り出す (文字列パス)
        local engine_root = (type(sel_engine) == "table" and sel_engine.value) or sel_engine

        if not engine_root then
             vim.notify("Invalid engine selection.", vim.log.levels.ERROR)
             return
        end

        -- 2. テンプレート選択
        local templates = find_templates(engine_root)
        if #templates == 0 then 
            vim.notify("No templates found in " .. engine_root, vim.log.levels.WARN)
            return 
        end

        unl_picker.pick({
            kind = "uep_new_project_template",
            title = "Select Template",
            items = templates,
            conf = conf,
            format = function(item) return item.display end,
            preview_enabled = false, -- ディレクトリのプレビューは重い場合があるので一旦OFF（ONでもfilenameがあれば動きます）
            on_submit = function(sel_template)
                if not sel_template then return end
                
                -- valueを取り出す (テーブル {name=..., path=...})
                local tpl = (type(sel_template) == "table" and sel_template.value) or sel_template
                if not tpl then tpl = sel_template end

                -- 3. プロジェクト名入力
                vim.ui.input({ prompt = "New Project Name: " }, function(project_name)
                    if not project_name or project_name == "" then return end
                    
                    if project_name:match("%s") then
                        vim.notify("Project name cannot contain spaces.", vim.log.levels.ERROR)
                        return
                    end

                    -- 4. 作成場所 (現在はCWD直下)
                    local cwd = vim.loop.cwd()
                    local target_dir = fs.joinpath(cwd, project_name)
                    
                    if vim.fn.isdirectory(target_dir) == 1 then
                        vim.notify("Directory already exists: " .. target_dir, vim.log.levels.ERROR)
                        return
                    end

                    vim.notify("Creating project '" .. project_name .. "'...", vim.log.levels.INFO)
                    
                    -- 5. 生成実行
                    vim.schedule(function()
                        copy_template_recursive(tpl.path, target_dir, tpl.name, project_name)
                        
                        local uproject_file = fs.joinpath(target_dir, project_name .. ".uproject")
                        if vim.fn.filereadable(uproject_file) == 1 then
                            local content = table.concat(vim.fn.readfile(uproject_file), "\n")
                            -- パス区切り文字をエスケープ (JSON内でのバックスラッシュ対応)
                            local safe_engine_root = engine_root:gsub("\\", "\\\\")

                            if content:match('"EngineAssociation":') then
                                content = content:gsub('"EngineAssociation":%s*".-"', '"EngineAssociation": "' .. safe_engine_root .. '"')
                            else
                                content = content:gsub('{', '{\n\t"EngineAssociation": "' .. safe_engine_root .. '",', 1)
                            end
                            
                            local f = io.open(uproject_file, "w")
                            if f then f:write(content); f:close() end
                        end

                        vim.notify("Project created at: " .. target_dir, vim.log.levels.INFO)
                        log.info("Created new project '%s' using engine '%s'", project_name, engine_root)
                        
                        local choice = vim.fn.confirm("Project created. Change directory to it?", "&Yes\n&No", 1)
                        if choice == 1 then
                            vim.api.nvim_set_current_dir(target_dir)
                            -- 新しいプロジェクトに入ったので、自動でrefreshをかけると親切
                            -- require("UEP.api").refresh()
                        end
                    end)
                end)
            end
        })
    end
  })
end

return M
