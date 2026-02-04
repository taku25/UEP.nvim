-- lua/UEP/cmd/core/grep_core.lua
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local unl_grep_picker = require("UNL.backend.grep_picker")
local unl_finder = require("UNL.finder")
local uep_utils = require("UEP.cmd.core.utils")

local M = {}

function M.start_live_grep(opts)
  local log = uep_log.get()

  -- STEP 1: プロジェクトの全モジュール情報を非同期で取得
  uep_utils.get_project_maps(vim.loop.cwd(), function(maps_ok, maps)
    if not maps_ok then
      log.error("grep: Failed to get project maps: %s", tostring(maps))
      return
    end
    
    -- ★★★ 1. 最終フォールバックで使うため、engine_rootもここで取得 ★★★
    local engine_root
    local proj_info = unl_finder.project.find_project(maps.project_root)
    if proj_info and proj_info.uproject then
      engine_root = unl_finder.engine.find_engine_root(proj_info.uproject,
        {
          engine_override_path = uep_config.get().engine_path,
        })
    end

    -- STEP 2: パス解決のためのデータを準備
    local sorted_modules = {}
    for name, data in pairs(maps.all_modules_map) do
      if data.module_root then
        table.insert(sorted_modules, {
          name = name,
          root = data.module_root,
          normalized_root = data.module_root:gsub("[\\]", "/"):lower(),
        })
      end
    end
    table.sort(sorted_modules, function(a, b) return #a.root > #b.root end)

    -- STEP 3: すべての知識を詰め込んだ、究極の表示変換関数を定義
    local transform_display_func = function(full_path)
      local normalized_full = full_path:gsub("[\\]", "/"):lower()

      -- (1) 最も優先度が高いのは、モジュールへの所属チェック
      for _, mod_info in ipairs(sorted_modules) do
        if normalized_full:find(mod_info.normalized_root, 1, true) then
          local relative_path = uep_utils.create_relative_path(full_path, mod_info.root)
          return string.format("%s/%s (%s)", mod_info.name, relative_path, mod_info.name)
        end
      end
      
      -- ★★★ 2. どのモジュールにも属さない場合の、最終フォールバックを追加 ★★★
      -- (2) 次に、エンジンルートに属しているかチェック
      if engine_root then
        local normalized_engine_root = engine_root:gsub("[\\]", "/"):lower()
        if normalized_full:find(normalized_engine_root, 1, true) then
          return uep_utils.create_relative_path(full_path, engine_root)
        end
      end
      
      -- (3) 最後に、プロジェクトルートに属しているかチェック
      if maps.project_root then
        local normalized_project_root = maps.project_root:gsub("[\\]", "/"):lower()
        if normalized_full:find(normalized_project_root, 1, true) then
          return uep_utils.create_relative_path(full_path, maps.project_root)
        end
      end
      
      -- (4) すべてのチェックを通過した場合、そのままのパスを返す
      return full_path
    end
    
    local conf = uep_config.get()

    -- STEP 4: 準備したすべての情報を使って、grep_pickerを呼び出す
    unl_grep_picker.pick({
      conf = conf,
      search_paths = opts.search_paths,
      title = opts.title,
      logger_name = "UEP", -- UEPのログ設定を使用する
      initial_query = opts.initial_query or "",
      transform_display = transform_display_func,
      include_extensions = opts.include_extensions or conf.files_extensions,
      exclude_directories = conf.excludes_directory,
      devicons_enabled = true,
      on_submit = function(selection)
        if selection and selection.filename and selection.lnum then
          vim.api.nvim_command("edit +" .. tostring(selection.lnum) .. " " .. vim.fn.fnameescape(selection.filename))
        else
          uep_log.get().warn("Invalid selection received from picker.")
        end
      end,
    })
  end)
end

return M
