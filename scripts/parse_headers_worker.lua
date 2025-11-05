-- scripts/parse_headers_worker.lua (ハッシュ計算ロジックを追加)

local json_decode = vim.json.decode
local json_encode = vim.json.encode
local matchlist = vim.fn.matchlist

----------------------------------------------------------------------
-- 1. ワーカー内パーサー (io.lines() ベース)
----------------------------------------------------------------------

local function strip_comments(text)
  text = text:gsub("/%*.-%*/", "")
  text = text:gsub("//[^\n]*", "")
  return text
end

-- ▼▼▼ [修正] UCLASS/USTRUCT ブロックをパースするヘルパー関数 ▼▼▼
-- (入力が `block_lines` (テーブル) から `block_text` (文字列) に変更)
local function process_class_struct_block(block_text, keyword_to_find, macro_type)
    local cleaned_text = strip_comments(block_text)
    local flattened_text = cleaned_text:gsub("[\n\r]", " "):gsub("%s+", " ")

    local vim_pattern
    if keyword_to_find == "struct" then
      vim_pattern = [[.\{-}\(USTRUCT\)\s*(.\{-})\s*struct\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*\(:\s*\(public\|protected\|private\)\s*\(\w\+\)\)\?]]
    else -- class
      vim_pattern = [[.\{-}\(UCLASS\|UINTERFACE\)\s*(.\{-})\s*class\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*:\s*\(public\|protected\|private\)\s*\(\w\+\)]]
    end
    
    local result = matchlist(flattened_text, vim_pattern)

    if result and #result > 0 and result[4] and result[4] ~= "" then
      local symbol_name = result[4]
      local parent_symbol
      if keyword_to_find == "struct" then
         parent_symbol = result[7] and result[7] ~= "" and result[7] or nil
      else -- class
         parent_symbol = result[6] and result[6] ~= "" and result[6] or nil
      end
      local is_interface = (macro_type == "UINTERFACE") or (parent_symbol == "UInterface")

      return {
        class_name = symbol_name, base_class = parent_symbol or (is_interface and nil or ((keyword_to_find == "class") and "UObject" or nil)),
        is_final = false, is_interface = is_interface, symbol_type = keyword_to_find,
      }
    end
    return nil
end

local function process_enum_block(block_text, macro_type)
  local cleaned_text = strip_comments(block_text)
  local flattened_text = cleaned_text:gsub("[\n\r]", " "):gsub("%s+", " ")

  -- 修正済みパターン
  local vim_pattern = [[\v(UENUM)\s*\(.*\)\s*enum\s+(class\s+)?(\w+)]]
  local result = vim.fn.matchlist(flattened_text, vim_pattern)

  if result and #result > 0 and result[4] and result[4] ~= "" then
    local symbol_name = result[4]
    return {
      class_name = symbol_name,
      base_class = nil,
      is_final = true,
      is_interface = false,
      symbol_type = "enum"
    }
  end
  return nil
end
-- ▲▲▲ ヘルパー関数ここまで ▲▲▲

-- ▼▼▼ [修正] パース関数 (入力が file_path から content_lines (テーブル) に変更) ▼▼▼
local function parse_header_from_lines(content_lines)
  local final_symbols = {}
  local state = "SCANNING"
  local block_lines = {}
  local macro_type = nil
  local keyword_to_find = nil
  
  for _, line in ipairs(content_lines) do
    if state == "SCANNING" then
        local is_uclass = line:find("UCLASS")
        local is_uinterface = line:find("UINTERFACE")
        local is_ustruct = line:find("USTRUCT")
        local is_uenum = line:find("UENUM")

        if is_uclass or is_uinterface or is_ustruct then
          state = "HUNTING_BODY_MACRO"
          block_lines = { line }
          macro_type = is_uclass and "UCLASS" or (is_uinterface and "UINTERFACE" or "USTRUCT")
          keyword_to_find = (macro_type == "USTRUCT") and "struct" or "class"
          
          if line:find("_BODY") then
            local symbol_info = process_class_struct_block(table.concat(block_lines, "\n"), keyword_to_find, macro_type)
            if symbol_info then table.insert(final_symbols, symbol_info) end
            state = "SCANNING"
            block_lines = {}
          end
        elseif is_uenum then
          state = "HUNTING_ENUM_END"
          block_lines = { line }
          macro_type = "UENUM"
        end
    elseif state == "HUNTING_BODY_MACRO" then
        table.insert(block_lines, line)
        
        if line:find("_BODY") then
          local symbol_info = process_class_struct_block(table.concat(block_lines, "\n"), keyword_to_find, macro_type)
          if symbol_info then table.insert(final_symbols, symbol_info) end
          state = "SCANNING"
          block_lines = {}
        end
    elseif state == "HUNTING_ENUM_END" then
        table.insert(block_lines, line)
        
        if line:find("};") then 
            local symbol_info = process_enum_block(table.concat(block_lines, "\n"), macro_type)
            if symbol_info then table.insert(final_symbols, symbol_info) end
            state = "SCANNING"
            block_lines = {}
        end
    end
  end

  if #final_symbols > 0 then
    return final_symbols
  else
    return nil
  end
end
-- ▲▲▲ パース関数修正完了 ▲▲▲


----------------------------------------------------------------------
-- 2. ワーカー・メインロジック (ハッシュ計算あり)
----------------------------------------------------------------------
local function main()
  
  -- ▼▼▼ [修正] ペイロードは {path, mtime, old_hash} のリスト ▼▼▼
  local raw_payload = io.read("*a")
  if not raw_payload or raw_payload == "" then
    io.stderr:write("[Worker] Error: Did not receive any payload from stdin.\n")
    vim.cmd("cquit!")
    return
  end
  
  local ok, files_data_list = pcall(json_decode, raw_payload)
  if not ok or type(files_data_list) ~= "table" then
    io.stderr:write("[Worker] Error: Failed to decode JSON payload or payload is not a list.\n")
    vim.cmd("cquit!")
    return
  end

  for i, file_data in ipairs(files_data_list) do
    local file_path = file_data.path
    local current_mtime = file_data.mtime
    local old_hash = file_data.old_hash
    
    if not current_mtime then
        io.stderr:write(("[Worker] Warning: Missing mtime for %s. Skipping.\n"):format(file_path))
        goto continue_loop
    end

    -- STEP 1: ファイル読み込み (ワーカー内で同期的I/O)
    local read_ok, lines = pcall(vim.fn.readfile, file_path)
    if not read_ok or not lines then
      io.stderr:write(("[Worker] Error: Could not read file %s\n"):format(file_path))
      goto continue_loop
    end
    
    -- STEP 2: ハッシュ計算
    local content = table.concat(lines, "\n")
    local new_hash = vim.fn.sha256(content)
    
    local result_for_file -- メインスレッドに返すJSONオブジェクト

    -- STEP 3: ハッシュ比較
    if old_hash and old_hash == new_hash then
        -- [!] ハッシュが一致した場合
        result_for_file = {
            path = file_path,
            status = "cache_hit",
            mtime = current_mtime -- mtime を返す (メインスレッドがキャッシュ更新に使う)
        }
    else
        -- [!] ハッシュが不一致、または old_hash がない (新規) 場合
        local classes = parse_header_from_lines(lines) -- 読み込んだ lines をパース
        
        result_for_file = {
            path = file_path,
            status = "parsed",
            mtime = current_mtime,
            data = {
                classes = classes,
                new_hash = new_hash
            }
        }
    end
    
    -- STEP 4: 結果を JSON Line として stdout に書き込む
    local output_ok, json_line = pcall(json_encode, result_for_file)
    if output_ok then
        io.write(json_line .. "\n")
    else
        io.stderr:write(("[Worker] Error: Failed to encode JSON line for %s\n"):format(file_path))
    end
    
    -- 50ファイルごと、または最後/最初 に flush
    if i % 50 == 0 or i == #files_data_list or i == 1 then
        io.stdout:flush()
    end
    
    ::continue_loop::
  end
  -- ▲▲▲ メインロジック修正完了 ▲▲▲
   pcall(io.stdout.flush) 

  vim.cmd("qall!")
end

main()
