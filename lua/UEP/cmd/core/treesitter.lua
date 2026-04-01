-- lua/UEP/cmd/core/treesitter.lua
local M = {}

--- 現在のカーソル位置のクラス名を取得します。
--- @return string|nil クラス名
function M.get_current_class_name()
  local has_ts, ts_utils = pcall(require, "nvim-treesitter.ts_utils")
  if not has_ts then return nil end

  local node = ts_utils.get_node_at_cursor()
  while node do
    if node:type() == "class_specifier" or node:type() == "struct_specifier" then
      -- 子ノードから識別子を探す
      for i = 0, node:child_count() - 1 do
        local child = node:child(i)
        if child:type() == "type_identifier" or child:type() == "identifier" then
          return vim.treesitter.get_node_text(child, 0)
        end
      end
    end
    node = node:parent()
  end
  return nil
end

return M
