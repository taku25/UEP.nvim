-- lua/UEP/cmd/system_open.lua (RPC Optimized)
local unl_api = require("UNL.api")
local uep_log = require("UEP.logger")
local unl_picker = require("UNL.picker")
local uep_config = require("UEP.config")

local M = {}

local function open_in_system_explorer(path)
  local logger = uep_log.get()
  local abs_path = vim.fn.fnamemodify(path, ":p")
  logger.info("System Open: %s", abs_path)

  if vim.fn.has("win32") == 1 or vim.fn.has("wsl") == 1 then
    -- PATH_CTE が生成する C:///path 形式を正規化してバックスラッシュに統一
    local win_path = abs_path
      :gsub("^\\\\?\\", "")        -- \\?\ UNC ロングパスプレフィックスを除去
      :gsub("^(%a:)/+", "%1/")     -- C:///path → C:/path (先にスラッシュ数を正規化)
      :gsub("/", "\\")             -- / → \ (explorer /select は \ が必須)
    win_path = win_path:gsub("^(%a)", function(d) return d:upper() end)  -- ドライブレター大文字化
    logger.debug("Explorer select path: [%s]", win_path)

    -- temp .bat ファイル経由で起動: libuv / shell のクォーティング問題を完全回避
    local tmp = vim.fn.tempname() .. ".bat"
    local f = io.open(tmp, "w")
    if f then
      f:write(string.format('@explorer /select,"%s"\r\n', win_path))
      f:close()
      vim.fn.jobstart({"cmd.exe", "/c", tmp}, {
        detach = true,
        on_exit = function() vim.fn.delete(tmp) end,
      })
    else
      logger.warn("Failed to create temp bat file: %s", tmp)
    end
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({"open", "-R", abs_path}, { detach = true })
  else
    local dir = vim.fn.fnamemodify(abs_path, ":h")
    vim.fn.jobstart({"xdg-open", dir}, { detach = true })
  end
end

local function pick_and_open()
  local logger = uep_log.get()
  local conf = uep_config.get()
  
  unl_api.db.get_all_file_paths(function(paths, err)
      if err or not paths or #paths == 0 then
        return logger.warn("No files found in UNL DB. Try :UNL refresh first.")
      end

      local items = {}
      for _, path in ipairs(paths) do
        table.insert(items, {
          display = path,
          value = path,
          filename = path
        })
      end

      unl_picker.open({
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
  end)
end

function M.execute(opts)
  opts = opts or {}
  if opts.has_bang then
    pick_and_open()
    return
  end
  if opts.path and opts.path ~= "" then
    open_in_system_explorer(opts.path)
    return
  end
  local current_file = vim.api.nvim_buf_get_name(0)
  if current_file ~= "" and vim.fn.filereadable(current_file) == 1 then
    open_in_system_explorer(current_file)
  else
    pick_and_open()
  end
end

return M
