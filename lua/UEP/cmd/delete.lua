-- lua/UEP/cmd/delete.lua
-- :UEP delete コマンドの実処理を担うモジュール

local projects_cache = require("UEP.cache.projects")
local unl_picker     = require("UNL.backend.picker")
local uep_log       = require("UEP.logger")

local M = {}

function M.execute(opts)
  -- 1. プロジェクト一覧キャッシュを読み込む (cd と同じ)
  local projects = projects_cache.load()
  if not next(projects) then
    vim.notify("No known projects to delete.", vim.log.levels.WARN)
    return
  end
  
  -- 2. Pickerで表示するためのアイテムリストを作成する (cd と同じ)
  local picker_items = {}
  for root_path, meta in pairs(projects) do
    table.insert(picker_items, {
      label = string.format("%s (%s)", meta.name, root_path),
      value = root_path,
    })
  end
  
  -- 3. UNLのPickerを起動する
  unl_picker.pick("project_delete", { -- kindは少し変えても良い
    title = "Select Project to DELETE from registry",
    items = picker_items,
    format = function(item) return item.label end,
     preview_enabled = false, 
     on_submit = function(selected_root_path)
      if not selected_root_path then return end
      
      -- 1. 確認プロンプトのメッセージを作成
      local prompt_str = ("Delete '%s' from registry?"):format(selected_root_path)
      
      -- 2. vim.ui.select で確認ダイアログを表示
      vim.ui.select(
        -- 選択肢
        { "Yes, remove from registry", "No, cancel" },
        -- オプション
        {
          prompt = prompt_str,
          -- (オプション) 各選択肢の見た目を少し整える
          format_item = function(item) return "  " .. item end,
        },
        -- コールバック関数
        function(choice)
          if not choice or choice ~= "Yes, remove from registry" then
            -- "No" が選ばれたか、<Esc> でキャンセルされた場合
            uep_log.get().info("Project deletion cancelled by user.")
            vim.notify("Deletion cancelled.", vim.log.levels.INFO)
            return
          end

          -- "Yes" が選択された場合
          uep_log.get().info("Deleting project from registry: %s", selected_root_path)
          ProjectsCache.remove(selected_root_path)
          vim.notify("Project removed from registry: " .. selected_root_path, vim.log.levels.INFO)
        end
      )
    end,
    
    on_cancel = function()
      uep_log.get().info("Project deletion picker cancelled.")
    end,
  })
end

return M
