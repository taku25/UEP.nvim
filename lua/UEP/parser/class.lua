-- lua/UEP/parser/class.lua (修正版)

local uep_log = require("UEP.logger").get()
local M = {}

----------------------------------------------------------------------
-- 解析関数 (変更なし)
----------------------------------------------------------------------
local function get_file_hash(file_path)
  local file, err = io.open(file_path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return vim.fn.sha256(content)
end

local function strip_comments(text)
  text = text:gsub("/%*.-%*/", "")
  text = text:gsub("//[^\n]*", "")
  return text
end

local function parse_single_header_with_user_logic(file_path)
  local read_ok, lines = pcall(vim.fn.readfile, file_path)
  if not read_ok then
    uep_log.warn("Could not read file for parsing: %s", file_path)
    return nil
  end

  local final_classes = {}
  local i = 1
  while i <= #lines do
    local line_content = lines[i]
    local is_uclass = line_content:find("UCLASS")
    local is_uinterface = line_content:find("UINTERFACE")
    local is_declare_class = line_content:find("DECLARE_CLASS")

    if is_uclass or is_uinterface then
      local macro_type = is_uclass and "UCLASS" or "UINTERFACE"
      local block_lines = {}
      local j = i
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
        
        local vim_pattern = [[.\{-}\(UCLASS\|UINTERFACE\)\s*(.\{-})\s*class\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*:\s*\(public\|protected\|private\)\s*\(\w\+\)]]
        local result = vim.fn.matchlist(flattened_text, vim_pattern)
        
        if result and #result > 0 and result[4] then
          local class_name = result[4]
          local parent_class = result[6]
          local is_interface = (macro_type == "UINTERFACE") or (parent_class == "UInterface")
          table.insert(final_classes, {
            class_name = class_name,
            base_class = parent_class or (is_interface and nil or "UObject"),
            is_final = false,
            is_interface = is_interface,
          })
        end
        i = j + 1
      else
        i = i + 1
      end

    elseif is_declare_class then
      -- --- 【ロジック2: UObject用】修正済みの後方探索ロジック ---
      for k = i - 1, 1, -1 do
        local prev_line = lines[k]
        local cleaned_prev_line = strip_comments(prev_line)

        if cleaned_prev_line:match("^%s*class") then
          -- UCLASS/UINTERFACEを除いた、class定義に特化した正規表現
          local vim_pattern = [[class\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*:\s*\(public\|protected\|private\)\s*\(\w\+\)]]
          local result = vim.fn.matchlist(cleaned_prev_line, vim_pattern)

          if result and #result > 0 and result[1] and result[1] ~= "" then
            local class_name = result[3]
            local parent_class = result[5] and result[5] ~= "" and result[5] or nil
            table.insert(final_classes, {
              class_name = class_name,
              base_class = parent_class,
              is_final = false,
              is_interface = false,
            })
            found_class_def = true
            break -- class定義を見つけたら後方探索を終了
          end
        end
      end
      i = i + 1
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
-- 非同期実行関数 (APIシグネチャ変更)
----------------------------------------------------------------------
function M.parse_headers_async(existing_header_details, header_files, progress, on_complete)
  local new_details = {}
  existing_header_details = existing_header_details or {}

  local total_header_file = #header_files
  local co = coroutine.create(function()
    progress:stage_define("header_analysis_detail", total_header_file)
    for i, file_path in ipairs(header_files) do
      progress:stage_update("header_analysis_detail", i, ("Parsing: %s (%d/%d)..."):format(vim.fn.fnamemodify(file_path, ":t"), i, total_header_file))
      
      -- ▼▼▼ 修正点: ハイブリッドキャッシュ検証ロジック ▼▼▼
      local existing_entry = existing_header_details[file_path]
      local current_mtime = vim.fn.getftime(file_path)

      -- 1. mtimeが同じなら、ファイルは変更なしとみなし、再利用（高速パス）
      if existing_entry and existing_entry.mtime and existing_entry.mtime == current_mtime then
        new_details[file_path] = existing_entry
      else
        -- 2. mtimeが違う場合、ハッシュを計算して本当に内容が変わったか確認
        local current_hash = get_file_hash(file_path)
        -- 2a. ハッシュが同じなら、mtimeだけ更新して再利用
        if existing_entry and existing_entry.file_hash and existing_entry.file_hash == current_hash then
          new_details[file_path] = existing_entry
          new_details[file_path].mtime = current_mtime -- mtimeだけ更新
        else
          -- 2b. ハッシュが違うなら、本当に変更があったので再パース
          local classes = parse_single_header_with_user_logic(file_path)
          if classes ~= nil then
            new_details[file_path] = { file_hash = current_hash, mtime = current_mtime, classes = classes }
          end
        end
      end
      -- ▲▲▲ ここまで ▲▲▲

      if i % 100 == 0 then coroutine.yield() end
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
