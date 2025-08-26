-- lua/UEP/cmd/cd.lua
-- :UEP cd コマンドの実処理を担うモジュール

local projects_cache = require("UEP.cache.projects")
local UNLPicker     = require("UNL.backend.picker") -- Pickerの本体を直接 require
local uep_log       = require("UEP.logger")

local M = {}

---
-- cdコマンドの本体
-- @param opts table APIから渡されるオプション (現在は未使用)
--
function M.execute(opts)
  -- 1. プロジェクト一覧キャッシュを読み込む
  local projects = projects_cache.load()
  
  -- projects は { [root_path] = { name, uproject_path }, ... } というテーブル
  if not next(projects) then
    vim.notify("No known projects found. Run :UEP refresh in a project first.", vim.log.levels.WARN)
    return
  end
  
  -- 2. Pickerで表示するためのアイテムリストを作成する
  local picker_items = {}
  for root_path, meta in pairs(projects) do
    table.insert(picker_items, {
      -- 表示用のラベル: "MyProject (C:/Users/.../MyProject)"
      label = string.format("%s (%s)", meta.name, root_path),
      -- on_submit に渡される値: プロジェクトのルートパス
      value = root_path,
    })
  end
  
  -- 3. UNLのPickerを起動する
  UNLPicker.pick("project", {
    title = "Select Project to Change Directory",
    items = picker_items,
    
    -- Pickerの各行の表示形式を定義する
    format = function(item)
      return item.label
    end,
    
    -- ユーザーがアイテムを選択したときの処理
    on_submit = function(selected_root_path)
      if not selected_root_path then return end
      
      uep_log.get().info("Changing directory to: %s", selected_root_path)
      
      -- NeovimのCWD (Current Working Directory) を変更する
      local ok, err = pcall(vim.api.nvim_set_current_dir, selected_root_path)
      
      if ok then
        vim.notify("Changed directory to: " .. selected_root_path, vim.log.levels.INFO)
      else
        uep_log.get().error("Failed to cd to '%s': %s", selected_root_path, tostring(err))
        vim.notify("Error: Could not change directory.", vim.log.levels.ERROR)
      end
    end,
    
    -- ユーザーがキャンセルしたときの処理
    on_cancel = function()
      uep_log.get().info("Project CD cancelled by user.")
    end,
  })
end

return M
