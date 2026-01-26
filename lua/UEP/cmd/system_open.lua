-- lua/UEP/cmd/system_open.lua
local uep_log = require("UEP.logger")
local unl_picker = require("UNL.backend.picker")
local uep_db = require("UEP.db.init")
local uep_config = require("UEP.config")

local M = {}

-- システムエクスプローラーで開く (UEAと同じロジック)
local function open_in_system_explorer(path)
  local logger = uep_log.get()
  local abs_path = vim.fn.fnamemodify(path, ":p")
  
  logger.info("System Open: %s", abs_path)

  if vim.fn.has("win32") == 1 or vim.fn.has("wsl") == 1 then
    local win_path = abs_path:gsub("/", "\\")
    local cmd = string.format('explorer /select,"%s"', win_path)
    vim.fn.jobstart({"cmd.exe", "/c", cmd}, {
      detach = true,
      on_exit = function(_, code)
        if code ~= 0 and code ~= 1 then -- 1は成功扱い
          logger.warn("Explorer command finished with code: %d", code)
        end
      end
    })
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({"open", "-R", abs_path}, { detach = true })
  else
    -- Linux
    local dir = vim.fn.fnamemodify(abs_path, ":h")
    vim.fn.jobstart({"xdg-open", dir}, { detach = true })
  end
end

-- UEPのDBから全ファイルを収集する
local function collect_all_files()
  local db = uep_db.get()
  if not db then return {} end

  local db_query = require("UEP.db.query")
  local paths = db_query.get_all_file_paths(db)
  if not paths then return {} end

  local files = {}
  for _, path in ipairs(paths) do
    table.insert(files, {
      display = path,
      value = path,
      filename = path
    })
  end
  return files
end

local function pick_and_open()
  local logger = uep_log.get()
  local conf = uep_config.get()
  
  -- DBからファイルリストを取得
  local items = collect_all_files()
  
  if #items == 0 then
    return logger.warn("No files found in UEP DB. Try :UEP refresh first.")
  end

  unl_picker.pick({
    kind = "uep_system_open",
    title = "Select File to Reveal (UEP)",
    items = items,
    conf = conf,
    logger_name = "UEP",
    preview_enabled = true,
    on_submit = function(selected)
      if selected then
        open_in_system_explorer(selected)
      end
    end,
  })
end

function M.execute(opts)
  opts = opts or {}
  
  -- 1. ! 付き -> Picker (プロジェクト全体から選択)
  if opts.has_bang then
    pick_and_open()
    return
  end

  -- 2. 引数あり -> 指定パスを開く
  if opts.path and opts.path ~= "" then
    open_in_system_explorer(opts.path)
    return
  end

  -- 3. 引数なし -> カレントバッファを開く
  local current_file = vim.api.nvim_buf_get_name(0)
  if current_file ~= "" and vim.fn.filereadable(current_file) == 1 then
    open_in_system_explorer(current_file)
  else
    -- バッファがない場合は入力プロンプトではなく、Pickerにフォールバックするのが親切
    pick_and_open()
  end
end

return M
