-- From: C:\Users\taku3\Documents\git\UEP.nvim\lua\UEP\cmd\purge.lua
-- lua/UEP/cmd/purge.lua (モジュールキャッシュ対応版)

local core_utils = require("UEP.cmd.core.utils")
-- local files_cache_manager = require("UEP.cache.files") -- [!] 削除
local module_cache = require("UEP.cache.module") -- [!] 追加
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")

local M = {}

---
-- 特定のコンポーネントに属する *全モジュール* のキャッシュを削除するコアロジック
-- @param component table 削除対象のコンポーネントメタデータ (p_cache)
local function purge_component_module_caches(component)
  local log = uep_log.get()

  -- [!] コンポーネントが持つモジュールリストを収集
  local modules_to_delete = {}
  local module_types_keys = { "runtime_modules", "developer_modules", "editor_modules", "programs_modules" }

  for _, type_key in ipairs(module_types_keys) do
    if component[type_key] then
      for mod_name, mod_meta in pairs(component[type_key]) do
        table.insert(modules_to_delete, mod_meta)
      end
    end
  end

  if #modules_to_delete == 0 then
    log.info("No modules found in component '%s' to purge.", component.display_name)
    vim.notify(string.format("No module caches found for component '%s'.", component.display_name), vim.log.levels.INFO)
    return true -- 削除対象がなかったので成功
  end

  log.info("Purging %d module caches for component: %s", #modules_to_delete, component.display_name)

  local success_count = 0
  for _, mod_meta in ipairs(modules_to_delete) do
    if module_cache.delete(mod_meta) then
      success_count = success_count + 1
    else
      log.warn("Failed to delete module cache for: %s", mod_meta.name)
    end
  end

  local all_succeeded = (success_count == #modules_to_delete)

  if all_succeeded then
    log.info("Successfully purged all %d module caches for component: %s", success_count, component.display_name)
    vim.notify(string.format("All %d module caches for component '%s' purged.", success_count, component.display_name), vim.log.levels.INFO)
  else
    log.error("Failed to purge %d out of %d module caches for component: %s", (#modules_to_delete - success_count), #modules_to_delete, component.display_name)
    vim.notify(string.format("Failed to purge some module caches for '%s'. Check logs.", component.display_name), vim.log.levels.ERROR)
  end

  return all_succeeded
end

---
-- コマンドビルダーから呼び出される実行関数
function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then return log.error("Could not get project maps: %s", tostring(maps)) end

    -- [!] all_components_map の中身は p_cache (コンポーネントメタデータ) そのもの
    local all_components = vim.tbl_values(maps.all_components_map)
    table.sort(all_components, function(a, b) return a.display_name < b.display_name end)

    -- コンポーネント特定後の処理をラップするローカル関数
    local function handle_purge_request(comp)
      -- [!] 確認メッセージを「モジュールキャッシュ」に変更
      local prompt_str = ("Permanently delete ALL MODULE caches for component '%s'? (This forces a file rescan on next refresh)"):format(comp.display_name)
      local choices = "&Yes\n&No"
      local decision = vim.fn.confirm(prompt_str, choices, 2) -- 2はデフォルトボタンの位置 ("No"をデフォルト)

      if decision == 1 then
        -- Yesが選択された場合のみ実行
        -- [!] 呼び出す関数を変更
        purge_component_module_caches(comp)
      else
        log.info("Module cache purge cancelled for component: %s", comp.display_name)
        vim.notify(string.format("Purge cancelled for '%s'.", comp.display_name), vim.log.levels.INFO)
      end
    end

    if not opts.component_name then
      -- 引数がない場合: ピッカーを表示して選択させる
      local picker_items = {}
      for _, comp in ipairs(all_components) do
        table.insert(picker_items, {
          label = string.format("%s [%s]", comp.display_name, comp.type),
          value = comp.name, -- comp.name は "Default_123_abc" のようなユニーク名
        })
      end

      unl_picker.pick({
        kind = "uep_select_component_to_purge",
        title = "Select Component (to purge its Module Caches)", -- [!] タイトル変更
        items = picker_items,
        conf = uep_config.get(),
        preview_enabled = false,
        on_submit = function(selected_comp_name)
          if selected_comp_name then
            local comp = maps.all_components_map[selected_comp_name]
            if comp then
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
        handle_purge_request(comp)
      else
        log.error("Component '%s' not found in project registry.", target_comp_name)
      end
    end
  end)
end
return M
