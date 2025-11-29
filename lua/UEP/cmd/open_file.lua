-- lua/UEP/cmd/open_file.lua (統合版)

-- 必要なモジュールをすべてここでrequireする
local core_utils = require("UEP.cmd.core.utils")
-- local files_cache_manager = require("UEP.cache.files") -- [!] 削除
local module_cache = require("UEP.cache.module") -- [!] 追加
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local shader_provider = require("UEP.provider.shader") -- ★追加

local M = {}

----------------------------------------------------------------------
-- 内部ヘルパー関数
----------------------------------------------------------------------

-- 複数の候補が見つかった場合にPickerを表示する
local function present_picker(candidates, partial_path)
  uep_log.get().info("Found multiple candidates for '%s'. Please select one.", partial_path)

  local picker_items = {}
  for _, item in ipairs(candidates) do
    if type(item) == "string" then
      table.insert(picker_items, { value = item, filename = item })
    else
      table.insert(picker_items, item)
    end
  end

  unl_picker.pick({
    kind = "uep_select_include_file",
    title = "Select a file to open",
    items = picker_items,
    conf = uep_config.get(),
    preview_enabled = true,
    on_submit = function(selection)
      if selection and selection ~= "" then
        vim.cmd.edit(vim.fn.fnameescape(selection))
      end
    end,
  })
end

-- IDEのようにスマートな階層的検索を実行するメインロジック
local function find_and_open(partial_path, from_path)
  local log = uep_log.get()
  partial_path = partial_path:gsub("\\", "/")

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then return log.error("Could not get project maps: %s", tostring(maps)) end

    if partial_path:match("%.us[hf]$") then
        log.debug("Detected shader file extension. Attempting shader path resolution...")
        
        -- provider/shader.lua で解決を試みる
        local resolved_shader = shader_provider.resolve(partial_path, maps)
        
        if resolved_shader then
            log.info("Resolved shader path: %s -> %s", partial_path, resolved_shader)
            vim.cmd("edit " .. vim.fn.fnameescape(resolved_shader))
            return -- シェーダーとして解決できたので終了
        else
            log.debug("Shader resolution failed for '%s'. Falling back to standard search.", partial_path)
            -- 解決できなかった場合は、通常のC++ファイルと同じ検索ロジックへ流す (フォールバック)
        end
    end
    local found_paths = {}
    local current_file_dir = vim.fn.fnamemodify(from_path, ":h")

    -- STEP 1: 自身のファイルが置かれている場所のディレクトリから検索
    local relative_to_current = fs.joinpath(current_file_dir, partial_path)
    if vim.fn.filereadable(relative_to_current) == 1 then
      log.info("Found in current directory: %s", relative_to_current)
      vim.cmd.edit(vim.fn.fnameescape(relative_to_current))
      return
    end

    local current_module = core_utils.find_module_for_path(from_path, maps.all_modules_map)
    if not current_module then
      log.warn("Could not determine the current module for '%s'. Skipping module-based search.", from_path)
    else
      -- STEP 2: モジュールルートからPublic/Privateフォルダを足して検索
      for _, folder in ipairs({ "Public", "Private", "Classes", "Sources" }) do
        local path = fs.joinpath(current_module.module_root, folder, partial_path)
        if vim.fn.filereadable(path) == 1 then
          log.info("Found in module %s folder: %s", folder, path)
          vim.cmd.edit(vim.fn.fnameescape(path))
          return
        end
      end
      
      -- STEP 3, 4, 5: 依存関係を検索
      local function search_dependencies(dep_names)
        local results = {}
        for _, dep_name in ipairs(dep_names) do
          local dep_module = maps.all_modules_map[dep_name]
          if dep_module and dep_module.module_root then
            local path_to_check = fs.joinpath(dep_module.module_root, "Public", partial_path)
            if vim.fn.filereadable(path_to_check) == 1 then
              table.insert(results, path_to_check)
            end
          end
        end
        return results
      end

      -- STEP 4: shallow_depsから検索
      found_paths = search_dependencies(current_module.shallow_dependencies or {})
      if #found_paths == 1 then
        log.info("Found in shallow dependencies: %s", found_paths[1])
        vim.cmd.edit(vim.fn.fnameescape(found_paths[1]))
        return
      elseif #found_paths > 1 then
        return present_picker(found_paths, partial_path)
      end

      -- STEP 5: deep_depsから検索
      found_paths = search_dependencies(current_module.deep_dependencies or {})
      if #found_paths == 1 then
        log.info("Found in deep dependencies: %s", found_paths[1])
        vim.cmd.edit(vim.fn.fnameescape(found_paths[1]))
        return
      elseif #found_paths > 1 then
        return present_picker(found_paths, partial_path)
      end
    end
    
    -- STEP 6: 全てのファイルから検索 (フォールバック)
    log.info("Not found in context-aware search. Falling back to global search...")
    local final_candidates = {}
    local seen = {}
    
    -- [!] all_components_map ではなく all_modules_map をイテレート
    for mod_name, mod_meta in pairs(maps.all_modules_map) do
      -- [!] module_cache をロード
      local cache = module_cache.load(mod_meta)
      if cache and cache.files then
        for category, file_list in pairs(cache.files) do
          for _, abs_path in ipairs(file_list) do
            if not seen[abs_path] and abs_path:gsub("\\", "/"):find(partial_path, 1, true) then
              table.insert(final_candidates, {
                -- [!] 相対パスの基準を component.root_path から mod_meta.module_root に変更
                display = core_utils.create_relative_path(abs_path, mod_meta.module_root),
                value = abs_path,
                filename = abs_path,
              })
              seen[abs_path] = true
            end
          end
        end
      end
    end

    if #final_candidates == 0 then
      log.warn("File not found anywhere in project cache: %s", partial_path)
    elseif #final_candidates == 1 then
      log.info("Found in global search: %s", final_candidates[1].value)
      vim.cmd.edit(vim.fn.fnameescape(final_candidates[1].value))
    else
      present_picker(final_candidates, partial_path)
    end
  end)
end

----------------------------------------------------------------------
-- 公開API
----------------------------------------------------------------------

-- コマンドビルダーから呼び出される実行関数
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  -- 1. 呼び出し元のファイルパスを決定する (引数がなければ現在のバッファ)
  local from_path = opts.from_path or vim.fn.expand('%:p')
  
  -- 2. 開きたいインクルードパスを決定する (引数がなければ現在の行から抽出)
  local path_to_open = opts.path
  if not path_to_open then
    path_to_open = vim.fn.getline('.'):match('["<]([^>"]+)[">]')
  end
  
  -- 3. 最終チェック
  if not path_to_open or path_to_open == "" then
    return log.warn("No include path found on the current line or provided as an argument.")
  end
  
  -- 4. 決定した引数でメインロジックを呼び出す
  find_and_open(path_to_open, from_path)
  
end

return M
