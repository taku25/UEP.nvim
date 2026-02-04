-- lua/UEP/cmd/goto_implementation.lua
local unl_api = require("UNL.api")
local ucm_core = require("UCM.cmd.core")
local uep_utils = require("UEP.cmd.core.utils")
local uep_log = require("UEP.logger")

local M = {}

function M.execute(opts)
  local log = uep_log.get()
  local symbol_name = vim.fn.expand("<cword>")
  if symbol_name == "" then return log.warn("No symbol under cursor.") end

  local current_file = vim.api.nvim_buf_get_name(0)
  local is_header = current_file:match("%.h$") or current_file:match("%.hpp$")

  log.info("Attempting goto_impl for: %s", symbol_name)

  -- 1. 対になるファイルを特定 (UCMのロジックを再利用)
  ucm_core.resolve_class_pair(current_file, function(pair, err)
    if not pair then
      return log.error("Could not find alternate file for: %s", vim.fn.fnamemodify(current_file, ":t"))
    end

    local target_file = is_header and pair.cpp or pair.h
    if not target_file or target_file == "" or vim.fn.filereadable(target_file) == 0 then
      return log.warn("Alternate file does not exist for: %s", symbol_name)
    end

    -- 2. DBからターゲットファイル内のシンボル情報を取得して行番号を特定
    unl_api.db.get_file_symbols(target_file, function(symbols)
      local target_line = 0
      
      -- シンボルリストを走査して名前が一致するものを探す
      local function find_in_list(list)
        for _, s in ipairs(list or {}) do
          -- 完全一致、または ClassName::FunctionName の形式での末尾一致をチェック
          if s.name == symbol_name or (s.name:match("::" .. symbol_name .. "$")) then 
            return s.line 
          end
        end
        return nil
      end

      if symbols then
        for _, cls in ipairs(symbols) do
          -- クラス名そのものがターゲットの場合
          if cls.name == symbol_name then
            target_line = cls.line
            break
          end
          -- メソッド内を探す
          for _, access in ipairs({"public", "protected", "private", "impl"}) do
            local line = find_in_list(cls.methods and cls.methods[access])
            if line then target_line = line; break end
            
            -- プロパティ内を探す
            line = find_in_list(cls.fields and cls.fields[access])
            if line then target_line = line; break end
          end
          if target_line > 0 then break end
        end
      end

      -- 3. ジャンプ実行
      -- DBに行番号があればそれを使う、なければ symbol_name ベースで検索ジャンプ
      if target_line and target_line > 0 then
        uep_utils.open_file_and_jump(target_file, symbol_name, target_line)
      else
        -- フォールバック: ファイル内検索
        -- CPPへ飛ぶ場合は ClassName::SymbolName を探したいが、ClassNameの特定が必要
        -- シンプルに symbol_name での検索に倒す
        log.debug("Symbol not found in DB for %s, falling back to pattern search.", target_file)
        uep_utils.open_file_and_jump(target_file, symbol_name)
      end
    end)
  end)
end

return M
