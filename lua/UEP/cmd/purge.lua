-- lua/UEP/cmd/purge.lua (新規作成)

local core_utils = require("UEP.cmd.core.utils")
local files_cache_manager = require("UEP.cache.files")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

---
-- 特定のコンポーネントのファイルキャッシュを削除するコアロジック
-- @param component table 削除対象のコンポーネントメタデータ
local function purge_component_cache(component)
  local log = uep_log.get()

  -- ★ 修正箇所: files_cache_managerの新しい公開APIに処理を委譲 ★
  local success = files_cache_manager.delete_component_cache_file(component)

  if success then
    log.info("Successfully purged file cache for component: %s", component.display_name)
    vim.notify(string.format("File cache for component '%s' purged.", component.display_name), vim.log.levels.INFO)
  else
    log.error("Failed to purge file cache for component: %s", component.display_name)
    vim.notify(string.format("Failed to purge cache for '%s'. Check logs.", component.display_name), vim.log.levels.ERROR)
  end
  
  return success
end

---
-- コマンドビルダーから呼び出される実行関数
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then return log.error("Could not get project maps: %s", tostring(maps)) end

    local all_components = vim.tbl_values(maps.all_components_map)
    table.sort(all_components, function(a, b) return a.display_name < b.display_name end)

    -- コンポーネント特定後の処理をラップするローカル関数
    local function handle_purge_request(comp)
      -- ★ 追加: vim.fn.confirm() で削除の最終確認を行う ★
      local prompt_str = ("Permanently delete the FILE cache for component '%s'?"):format(comp.display_name)
      local choices = "&Yes\n&No"
      local decision = vim.fn.confirm(prompt_str, choices, 2) -- 2はデフォルトボタンの位置 ("No"をデフォルト)

      if decision == 1 then
        -- Yesが選択された場合のみ実行
        purge_component_cache(comp)
      else
        log.info("File cache purge cancelled for component: %s", comp.display_name)
        vim.notify(string.format("Purge cancelled for '%s'.", comp.display_name), vim.log.levels.INFO)
      end
    end

    if not opts.component_name then
      -- 引数がない場合: ピッカーを表示して選択させる
      local picker_items = {}
      for _, comp in ipairs(all_components) do
        table.insert(picker_items, {
          label = string.format("%s [%s]", comp.display_name, comp.type),
          value = comp.name, 
        })
      end
      
      unl_picker.pick({
        kind = "uep_select_component_to_purge",
        title = "Select Component Cache to Purge",
        items = picker_items,
        conf = uep_config.get(),
        preview_enabled = false,
        on_submit = function(selected_comp_name)
          if selected_comp_name then
            local comp = maps.all_components_map[selected_comp_name]
            if comp then
              -- 確認処理へ移動
              handle_purge_request(comp) 
            end
          end
        end,
      })
    else
      -- 引数がある場合: 直接削除を実行
      local target_comp_name = opts.component_name
      local comp = maps.all_components_map[target_comp_name]
      if comp then
        -- 確認処理へ移動
        handle_purge_request(comp)
      else
        log.error("Component '%s' not found in project registry.", target_comp_name)
      end
    end
  end)
end
return M
