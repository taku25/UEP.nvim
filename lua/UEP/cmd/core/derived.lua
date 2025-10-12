-- lua/UEP/cmd/core/derived.lua

local core_utils = require("UEP.cmd.core.utils")
local files_cache_manager = require("UEP.cache.files")

local M = {}

---
-- プロジェクト内の全てのC++クラス情報を非同期で収集する
-- @param on_complete function(class_list) コールバック関数
-- class_list: { { class_name="..", base_class="..", file_path=".." }, ... }
function M.get_all_classes(on_complete)
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      if on_complete then on_complete(nil) end
      return
    end

    local all_classes = {}
    for _, component in pairs(maps.all_components_map) do
      local files_cache = files_cache_manager.load_component_cache(component)
      if files_cache and files_cache.header_details then
        for file_path, details in pairs(files_cache.header_details) do
          if details.classes then
            for _, class_info in ipairs(details.classes) do
              table.insert(all_classes, {
                class_name = class_info.class_name,
                base_class = class_info.base_class,
                file_path = file_path,
              })
            end
          end
        end
      end
    end

    table.sort(all_classes, function(a, b) return a.class_name < b.class_name end)
    if on_complete then on_complete(all_classes) end
  end)
end

---
-- 全クラスリストから、指定された基底クラスを継承するクラスを検索する
-- @param base_class_name string 検索する基底クラス名
-- @param all_classes_data table M.get_all_classes() で取得した全クラスのリスト
-- @return table 発見された派生クラスのリスト
function M.find_derived_in_list(base_class_name, all_classes_data)
  local derived_classes = {}
  local base_name_without_prefix = base_class_name:gsub("^[AUF]", "")

  for _, class_data in ipairs(all_classes_data) do
    if class_data.base_class then
      -- プレフィックス(A, U, F)を除いたクラス名で比較
      local current_base_name_without_prefix = class_data.base_class:gsub("^[AUF]", "")
      if current_base_name_without_prefix == base_name_without_prefix then
        table.insert(derived_classes, class_data)
      end
    end
  end
  return derived_classes
end

return M
