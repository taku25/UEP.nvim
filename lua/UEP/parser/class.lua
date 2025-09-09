-- lua/UEP/parser/class.lua (ユーザー提供のロジックを組み込んだ最終完成版)

local uep_log = require("UEP.logger").get()
local M = {}

----------------------------------------------------------------------
-- 解析関数
----------------------------------------------------------------------

local function get_file_hash(file_path)
  local file, err = io.open(file_path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return vim.fn.sha256(content)
end

-- いただいたコメント除去関数
local function strip_comments(text)
  text = text:gsub("/%*.-%*/", "")
  text = text:gsub("//[^\n]*", "")
  return text
end

--- 単一のヘッダーファイルを、いただいたロジックで解析する
local function parse_single_header_with_user_logic(file_path)
  local read_ok, lines = pcall(vim.fn.readfile, file_path)
  if not read_ok then
    uep_log.warn("Could not read file for parsing: %s", file_path)
    return nil -- 戻り値をnilに統一
  end

  local final_classes = {}
  local i = 1
  while i <= #lines do
    -- ▼▼▼ 変更点 1: UCLASS または UINTERFACE を探す ▼▼▼
    local line_content = lines[i]
    local is_uclass = line_content:find("UCLASS")
    local is_uinterface = line_content:find("UINTERFACE")

    if is_uclass or is_uinterface then
      -- どちらのマクロが見つかったかを保存
      local macro_type = is_uclass and "UCLASS" or "UINTERFACE"

      local block_lines = {}
      local j = i
      -- UCLASS/UINTERFACEから_BODY()までをブロックとして収集
      while j <= #lines do
        table.insert(block_lines, lines[j])
        if lines[j]:find("_BODY") then
          break
        end
        j = j + 1
      end

      if j <= #lines then
        local block_text = table.concat(block_lines, "\n")
        local cleaned_text = strip_comments(block_text)
        local flattened_text = cleaned_text:gsub("[\n\r]", " "):gsub("%s+", " ")
        
        -- ▼▼▼ 変更点 2: Vim正規表現パターンを修正 ▼▼▼
        -- 先頭に \(UCLASS\|UINTERFACE\) を追加して、どちらのマクロにもマッチするようにする
        -- ただし、flattened_textの先頭にあるとは限らないので、.*も先頭に追加
        local vim_pattern = [[.\{-}\(UCLASS\|UINTERFACE\)\s*(.\{-})\s*class\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*:\s*\(public\|protected\|private\)\s*\(\w\+\)]]

        local result = vim.fn.matchlist(flattened_text, vim_pattern)
        
        -- matchlistのインデックスがずれるので調整
        if result and #result > 0 and result[4] then
          local api_macro = result[3]
          local class_name = result[4]
          local parent_class = result[6]
          
          -- ▼▼▼ 変更点 3: is_interface の判定を強化 ▼▼▼
          local is_interface = (macro_type == "UINTERFACE") or (parent_class == "UInterface")

          table.insert(final_classes, {
            class_name = class_name,
            base_class = parent_class or (is_interface and nil or "UObject"),
            is_final = false,
            is_interface = is_interface,
          })
        else
          uep_log.trace("Vim Regex did not match in flattened block for file: %s", vim.fn.fnamemodify(file_path, ":t"))
        end

        i = j + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  if #final_classes > 0 then
    return final_classes
  else
    return nil
  end
end

----------------------------------------------------------------------
-- 非同期実行関数 (変更なし)
----------------------------------------------------------------------

function M.parse_headers_async(root_path, header_files, progress, on_complete)
  local existing_cache = (require("UEP.cache.files").load(root_path) or {}).header_details or {}
  local new_details = {}

  local total_header_file = #header_files
  local co = coroutine.create(function()
    progress:stage_define("header_analysis_detail", total_header_file)
    for i, file_path in ipairs(header_files) do

        -- progress:stage_update("create_file_cache", (i / total_files), ("Processing files (%d/%d)..."):format(i, total_files))
      progress:stage_update("header_analysis_detail", i, ("Parsing: %s (%d/%d)..."):format(vim.fn.fnamemodify(file_path, ":t"), i, total_header_file))
      local current_hash = get_file_hash(file_path)

      -- ▼▼▼ このブロックを修正 ▼▼▼
      if existing_cache[file_path] and existing_cache[file_path].file_hash == current_hash then
        -- キャッシュが有効な場合はそのまま使う
        -- (UCLASSがないファイルは元々キャッシュにないので、この処理で問題ない)
        new_details[file_path] = existing_cache[file_path]
      else
        -- 新しく解析
        local classes = parse_single_header_with_user_logic(file_path)
        
        -- classesがnilでない（＝UCLASSが見つかった）場合のみ、
        -- new_detailsにエントリを追加する
        if classes ~= nil then
          new_details[file_path] = { file_hash = current_hash, classes = classes }
        else
          -- UCLASSがなかったので、このファイルは無視する
          uep_log.trace("Skipping file (no UCLASS found): %s", vim.fn.fnamemodify(file_path, ":t"))
        end
      end
      if i % 50 == 0 then coroutine.yield() end
    end
    on_complete(true, new_details)
  end)
  local function resume_handler()
    local status = coroutine.status(co)
    if status ~= "dead" then
      local ok, err = coroutine.resume(co)
      if not ok then
        uep_log.error("Error during header parsing coroutine: %s", tostring(err))
        on_complete(false, nil)
        return
      end
      vim.defer_fn(resume_handler, 1)
    end
  end
  resume_handler()
end

return M
