local core_utils = require("UEP.cmd.core.utils")
local uep_db = require("UEP.db.init")
local unl_picker = require("UNL.backend.picker")
local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local fs = require("vim.fs")

local M = {}

---
-- Target.csファイルを選択するピッカーを表示
local function show_picker(targets, project_root, title_suffix)
  local picker_items = {}

  for _, target in ipairs(targets) do
    local display_path = target.path
    if display_path and project_root then
        display_path = core_utils.create_relative_path(display_path, project_root)
    end

    table.insert(picker_items, {
      label = string.format("%s (%s)", target.name, target.type),
      value = target,
      display_path = display_path or "Unknown path"
    })
  end

  table.sort(picker_items, function(a, b) return a.label < b.label end)

  unl_picker.pick({
    kind = "uep_target_cs",
    title = "Select Target.cs" .. (title_suffix or ""),
    items = picker_items,
    conf = uep_config.get(),
    preview_enabled = false,
    format = function(item)
      return string.format("%-30s  %s", item.label, item.display_path)
    end,
    on_submit = function(selection)
      -- pathがあれば直接開く。なければ検索フォールバック
      if selection and selection.value and selection.value.path then
         vim.cmd.edit(vim.fn.fnameescape(selection.value.path))
      elseif selection and selection.value and selection.value.name then
        local target_filename = selection.value.name .. ".Target.cs"
        local find_cmd = { "fd", "-t", "f", "-p", target_filename, project_root }
        vim.fn.jobstart(find_cmd, {
          stdout_buffered = true,
          on_stdout = function(_, data)
            if data and data[1] and data[1] ~= "" then
              vim.schedule(function() vim.cmd.edit(vim.fn.fnameescape(data[1])) end)
            else
               uep_log.get().error("Could not find file: %s", target_filename)
            end
          end
        })
      end
    end,
  })
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    if not ok or not maps.game_component_name then
      return log.error("Failed to get project maps or game component name.")
    end

    local db = uep_db.get()
    if not db then return log.error("DB not available") end

    local rows = db:eval("SELECT path, filename FROM files WHERE filename LIKE '%.Target.cs'")
    if not rows or #rows == 0 then
      return log.warn("No build targets found in DB. Run :UEP refresh.")
    end

    local all_targets = {}
    for _, row in ipairs(rows) do
      local name = row.filename:gsub("%.Target%.cs$", "")
      table.insert(all_targets, {
        name = name,
        path = row.path,
        type = "Target"
      })
    end
    local filtered_targets = {}
    local project_root = maps.project_root

    -- ▼▼▼ フィルタリングロジック (pathを利用) ▼▼▼
    if opts.has_bang then
      -- Bangあり (!): すべて表示 (Engine含む)
      filtered_targets = all_targets
    else
      -- Bangなし: プロジェクト内のターゲットのみ
      for _, t in ipairs(all_targets) do
        -- target.path が プロジェクトルート以下にあるかチェック
        if t.path and t.path:find(project_root, 1, true) then
          table.insert(filtered_targets, t)
        end
      end
    end
    -- ▲▲▲ ここまで ▲▲▲

    if #filtered_targets == 0 then
      if opts.has_bang then
        return log.warn("No targets found in cache.")
      else
        return log.warn("No project targets found. Try ':UEP target_cs!' to include Engine targets.")
      end
    end

    -- ターゲットが1つしかない場合は即座に開く
    if #filtered_targets == 1 then
        local target = filtered_targets[1]
        
        -- Path情報があれば即オープン
        if target.path and vim.fn.filereadable(target.path) == 1 then
            log.info("Opening only target found: %s", target.name)
            vim.cmd.edit(vim.fn.fnameescape(target.path))
            return
        end
        -- Pathがない場合のフォールバックは省略（refreshされていればpathはあるはず）
    end

    local title_suffix = opts.has_bang and " (All/Engine)" or " (Project Only)"
    show_picker(filtered_targets, maps.project_root, title_suffix)
  end)
end

return M
