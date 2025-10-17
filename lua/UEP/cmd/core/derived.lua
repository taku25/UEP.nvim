-- lua/UEP/cmd/core/derived.lua (新規作成)

local core_utils = require("UEP.cmd.core.utils")
local files_cache_manager = require("UEP.cache.files")
local uep_log = require("UEP.logger")

local M = {}

---
-- プロジェクト内の全てのC++クラス情報を非同期で収集する
-- @param on_complete function(class_list | nil)
function M.get_all_classes(on_complete)
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
      uep_log.get().error("get_all_classes: Failed to get project maps: %s", tostring(maps))
      if on_complete then on_complete(nil) end
      return
    end

    local all_classes = {}
    if not maps.all_components_map then
      uep_log.get().warn("get_all_classes: No components found in project maps.")
      if on_complete then on_complete({}) end
      return
    end

    for _, component in pairs(maps.all_components_map) do
      local files_cache = files_cache_manager.load_component_cache(component)
      if files_cache and files_cache.header_details then
        for file_path, details in pairs(files_cache.header_details) do
          if details.classes then
            for _, class_info in ipairs(details.classes) do
              -- Pickerで使いやすいように、必要な情報をすべて含める
              table.insert(all_classes, {
                display = class_info.class_name, -- Picker表示用
                class_name = class_info.class_name,
                base_class = class_info.base_class,
                file_path = file_path,
                filename = file_path, -- プレビュー用
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
-- 指定された基底クラスのすべての子孫クラス（孫以降も含む）を再帰的に検索する
-- @param base_class_name string 基底クラス名
-- @param on_complete function(derived_list | nil)
function M.get_derived_classes(base_class_name, on_complete)
  M.get_all_classes(function(all_classes_data)
    if not all_classes_data then
      if on_complete then on_complete(nil) end
      return
    end

    -- 親から直接の子への関係をマップする（高速化のため）
    local parent_to_children = {}
    for _, class_data in ipairs(all_classes_data) do
      if class_data.base_class then
        parent_to_children[class_data.base_class] = parent_to_children[class_data.base_class] or {}
        table.insert(parent_to_children[class_data.base_class], class_data)
      end
    end

    local derived_classes = {}
    local visited = {} -- 無限ループ防止

    -- 再帰的に子孫を探すヘルパー関数
    local function find_recursively(current_base_name)
      if visited[current_base_name] then return end
      visited[current_base_name] = true

      local direct_children = parent_to_children[current_base_name]
      if direct_children then
        for _, child_info in ipairs(direct_children) do
          table.insert(derived_classes, child_info)
          -- 見つかった子クラスを新たな基底クラスとして、さらに子孫を探す
          find_recursively(child_info.class_name)
        end
      end
    end

    find_recursively(base_class_name)

    table.sort(derived_classes, function(a, b) return a.class_name < b.class_name end)
    if on_complete then on_complete(derived_classes) end
  end)
end

return M
