-- lua/UEP/cmd/program_files.lua

local files_cache_manager = require("UEP.cache.files")
local core_utils = require("UEP.cmd.core.utils")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")

local M = {}

function M.execute(opts)
  -- STEP 1: プロジェクトの全コンポーネント情報を取得
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      return uep_log.get().error("Failed to get project maps: %s", tostring(maps))
    end

    -- STEP 2: 全コンポーネントをスキャンし、"programs"カテゴリのファイルを集める
    local program_files = {}
    for _, component in pairs(maps.all_components_map) do
      local component_cache = files_cache_manager.load_component_cache(component)
      if component_cache and component_cache.files and component_cache.files.programs then
        for _, file_path in ipairs(component_cache.files.programs) do
          table.insert(program_files, {
            file_path = file_path,
            component = component,
          })
        end
      end
    end

    if #program_files == 0 then
      return uep_log.get().warn("No program files found in this project.")
    end

    -- STEP 3: ピッカーで表示するために整形する
    local picker_items = {}
    for _, item in ipairs(program_files) do
      local relative_path = core_utils.create_relative_path(item.file_path, item.component.root_path)
      table.insert(picker_items, {
        display = string.format("%s/%s", item.component.display_name, relative_path),
        value = item.file_path,
        filename = item.file_path,
      })
    end
    table.sort(picker_items, function(a, b) return a.display < b.display end)

    -- STEP 4: ピッカーを起動
    unl_picker.pick({
      kind = "uep_program_files",
      title = "ﬧ Programs Files",
      items = picker_items,
      conf = uep_config.get(),
      preview_enabled = true,
      devicons_enabled = true,
      on_submit = function(selection)
        if selection and selection ~= "" then
          pcall(vim.cmd.edit, vim.fn.fnameescape(selection))
        end
      end,
    })
  end)
end

return M
