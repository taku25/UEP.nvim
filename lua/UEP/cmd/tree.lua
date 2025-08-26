-- lua/UEP/cmd/tree.lua
-- :UEP tree コマンドの実処理
-- Pickerでモジュールを一つ選択し、そのルートをファイラーで開く

local project_cache = require("UEP.cache.project")
local uep_config = require("UEP.config")
local log = require("UEP.logger").get()
-- ★UNLのPickerとFilerを直接利用する
local unl_picker = require("UNL.backend.picker")
local unl_filer = require("UNL.backend.filer")

local M = {}

function M.execute(opts)
  -- 1. GameとEngineの全モジュール情報をロードして集約する (これは以前と同じ)
  local game_data = project_cache.load(vim.loop.cwd())
  if not game_data then
    log.error("Project cache not found. Run :UEP refresh first.")
    return
  end
  local engine_data = game_data.link_engine_cache_root
    and project_cache.load(game_data.link_engine_cache_root) or nil
  local all_modules = {}
  if game_data and game_data.modules then
    for name, meta in pairs(game_data.modules) do all_modules[name] = meta end
  end
  if engine_data and engine_data.modules then
    for name, meta in pairs(engine_data.modules) do
      if not all_modules[name] then all_modules[name] = meta end
    end
  end

  if not next(all_modules) then
    log.warn("No modules found in the cache.")
    return
  end

  -- 2. Pickerで表示するためのアイテムリストを作成する
  local picker_items = {}
  for name, meta in pairs(all_modules) do
    if meta.module_root then -- ルートパスが存在するモジュールのみ対象
      table.insert(picker_items, {
        -- 表示ラベル: "MyGame (Game)"
        label = string.format("%s (%s)", name, meta.category),
        -- 選択されたときにFilerに渡す値
        value = {
          name = name,
          path = meta.module_root,
        },
      })
    end
  end
  -- 見やすいように名前でソート
  table.sort(picker_items, function(a, b) return a.label < b.label end)

  -- 3. UNLのPickerを起動して、ユーザーにモジュールを選択させる
  unl_picker.pick({
    kind = "uep_module_select_for_tree",
    title = "Select a Module to Open in Filer",
    items = picker_items,
    conf = uep_config.get(),
     preview_enabled = false,
    logger_name = require("UEP.logger").name,
    format = function(item) return item.label end,

    -- ユーザーがモジュールを選択したときの処理
    on_submit = function(selected_module)
      if not selected_module or not selected_module.path then return end

      log.info("Opening module '%s' in filer at path: %s", selected_module.name, selected_module.path)

      -- 4. ★★★ UNLのFilerプロバイダーを呼び出す ★★★
      -- これでneo-treeや将来の他のファイラーもサポートできる
      unl_filer.open({
        conf = uep_config.get(),
        logger_name = require("UEP.logger").name,
        -- Filerに渡すのは単一のルート
        roots = {
          {
            name = selected_module.name,
            path = selected_module.path,
          }
        },
      })
    end,
  })
end

return M
