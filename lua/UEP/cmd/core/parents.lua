-- lua/UEP/cmd/core/parents.lua

local M = {}

---
-- 指定されたクラスの継承チェーンを遡ってリストを生成する
-- @param child_class_name string 継承元をたどりたいクラス名
-- @param all_classes_data table 全クラスのリスト
-- @return table 継承チェーンのリスト (親 -> 祖父母 -> ...)
function M.get_inheritance_chain(child_class_name, all_classes_data)
  -- 高速なルックアップのためにクラス名をキーとするマップを作成
  local class_map = {}
  for _, class_info in ipairs(all_classes_data) do
    class_map[class_info.class_name] = class_info
  end

  local inheritance_chain = {}
  local current_class_name = child_class_name
  local visited = {} -- 無限ループ防止用

  while current_class_name and not visited[current_class_name] do
    visited[current_class_name] = true
    local current_class_info = class_map[current_class_name]

    if current_class_info and current_class_info.base_class then
      local parent_info = class_map[current_class_info.base_class]
      if parent_info then
        table.insert(inheritance_chain, parent_info)
        current_class_name = parent_info.class_name
      else
        -- 親クラスがリストに見つからなければ終了
        break
      end
    else
      -- 親クラスがない、または現在のクラス情報が見つからなければ終了
      break
    end
  end

  return inheritance_chain
end

return M
