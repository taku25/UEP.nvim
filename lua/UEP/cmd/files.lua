-- lua/UEP/cmd/files.lua (第三世代・最終完成版)

local files_core = require("UEP.cmd.files_core")
local unl_picker = require("UNL.backend.picker")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
-- (project_cache や refresh_cmd はもはや不要)

local M = {}

-- ピッカー表示用のヘルパー関数 (変更なし)
local function show_picker(items, project_root)
  if not items or #items == 0 then
    uep_log.get().info("No matching files found.", "info")
    return
  end
  local picker_items = {};
  local root_prefix = project_root .. "/"
  for _, file_path in ipairs(items) do
    table.insert(picker_items, {
      label = file_path:gsub(root_prefix, ""),
      value = { filename = file_path, text = file_path:gsub(root_prefix, "") }
    })
  end
  table.sort(picker_items, function(a, b) return a.label < b.label end)
  unl_picker.pick({
    kind = "file_location", 
    title = " Source & Config Files",
    items = picker_items,
    preview_enabled = true,
    conf = uep_config.get(),
    logger_name = uep_log.name,
    on_submit = function(selection)
      if selection and selection.filename then
        pcall(vim.cmd.edit, selection.filename)
      end
    end
  })
end

-- メインの実行関数 (非同期コールバック対応)
function M.execute(opts)
  local log = uep_log.get()
  log.info("Assembling file list for the project...")

  -- 1. 組立工場に、非同期でファイルの組み立てを依頼
  files_core.get_merged_files_for_project(vim.loop.cwd(), opts, function(ok, merged_data)
    if not ok or not merged_data then
      log.error("Failed to assemble file list: %s", tostring(merged_data))
      return
    end
    
    -- 2. 組み立て完了後、どのカテゴリのファイルを表示するか決定
    --    (将来的に、:UEP files --config のようなフィルタリングをここで実装できる)
    local final_files = {}
    vim.list_extend(final_files, merged_data.files.source)
    vim.list_extend(final_files, merged_data.files.config)
    vim.list_extend(final_files, merged_data.files.shader)
    vim.list_extend(final_files, merged_data.files.programs)
    vim.list_extend(final_files, merged_data.files.other)
    
    -- 3. 完成品をピッカーに渡して表示
    --    プロジェクトルートを特定する必要があるが、cwdから再度探すのが一番シンプル
    local project_root = require("UNL.finder").project.find_project_root(vim.loop.cwd())
    show_picker(final_files, project_root)
  end)
end

return M
