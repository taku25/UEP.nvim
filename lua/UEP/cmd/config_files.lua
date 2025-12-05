-- lua/UEP/cmd/config_files.lua
local module_cache = require("UEP.cache.module")
local core_utils = require("UEP.cmd.core.utils")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  log.debug("Executing :UEP config...")
  local start_time = os.clock()

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      log.error("config_files: Failed to get project maps: %s", tostring(maps))
      return vim.notify("Error getting project maps.", vim.log.levels.ERROR)
    end

    local config_files_with_context = {}
    local modules_processed = 0

    -- STEP 1: "Real" Modules (全てのモジュールをスキャン)
    for mod_name, mod_meta in pairs(maps.all_modules_map) do
        local mod_cache_data = module_cache.load(mod_meta)
        
        -- "config" カテゴリのファイルのみを収集
        if mod_cache_data and mod_cache_data.files and mod_cache_data.files.config then
            for _, file_path in ipairs(mod_cache_data.files.config) do
                table.insert(config_files_with_context, {
                    file_path = file_path,
                    module_name = mod_name,
                    module_root = mod_meta.module_root,
                    category = "config",
                })
            end
        end
        modules_processed = modules_processed + 1
    end

    -- STEP 2: "Pseudo" Modules (Game/Engine/Plugin のルート Config)
    local pseudo_module_files = {}
    
    if maps.engine_root then
        pseudo_module_files["_EngineConfig"] = { root=fs.joinpath(maps.engine_root, "Engine", "Config") }
    end
    
    -- Engine/Config 以外に、各コンポーネント(Game/Plugin)のルートConfigも収集
    for comp_name_hash, comp_meta in pairs(maps.all_components_map) do
      if comp_meta.type == "Game" or comp_meta.type == "Plugin" then
          -- 修正: キャッシュ名は [Type]_[DisplayName] で保存されている
          local pseudo_name = comp_meta.type .. "_" .. comp_meta.display_name
          
          if not pseudo_module_files[pseudo_name] then
              pseudo_module_files[pseudo_name] = { root = comp_meta.root_path }
          end
      end
    end

    for pseudo_name, data in pairs(pseudo_module_files) do
        local pseudo_meta = { name = pseudo_name, module_root = data.root }
        local pseudo_cache = module_cache.load(pseudo_meta)
        
        if pseudo_cache and pseudo_cache.files and pseudo_cache.files.config then
            for _, file_path in ipairs(pseudo_cache.files.config) do
                table.insert(config_files_with_context, {
                    file_path = file_path,
                    module_name = pseudo_name,
                    module_root = data.root,
                    category = "config",
                })
            end
        end
    end
    
    local total_files_found = #config_files_with_context
    log.debug("config_files: Aggregated %d config files from %d modules (and pseudo-modules).", total_files_found, modules_processed)

    if total_files_found == 0 then
      return vim.notify("No config files found.", vim.log.levels.INFO)
    end

    -- STEP 3: ピッカーで表示するために整形
    local picker_items = {}
    for _, item in ipairs(config_files_with_context) do
      if item.module_root then
          local relative_path = core_utils.create_relative_path(item.file_path, item.module_root)
          table.insert(picker_items, {
            display = string.format("%s/%s (%s)", item.module_name, relative_path, item.module_name),
            value = item.file_path,
            filename = item.file_path,
          })
      else
           table.insert(picker_items, {
               display = item.file_path,
               value = item.file_path,
               filename = item.file_path,
           })
      end
    end
    table.sort(picker_items, function(a, b) return a.display < b.display end)

    local end_time = os.clock()
    log.info("config_files: Finished processing in %.4f seconds. Showing picker with %d items.",
             end_time - start_time, #picker_items)

    -- STEP 4: ピッカーを起動
    unl_picker.pick({
      kind = "uep_config_files",
      title = " Config Files",
      items = picker_items,
      conf = uep_config.get(),
      preview_enabled = true,
      devicons_enabled = true,
      
      file_ignore_patterns = {},
      find_files_ignore_patterns = {},
      hidden = true,

      on_submit = function(selection)
        if selection and selection ~= "" then
          pcall(vim.cmd.edit, vim.fn.fnameescape(selection))
        end
      end
    })
  end)
end

return M
