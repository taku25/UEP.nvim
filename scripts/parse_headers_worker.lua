-- scripts/parse_headers_worker.lua (ハッシュ計算削除 + Regex修正版)

local json_decode = vim.json.decode
local json_encode = vim.json.encode
local matchlist = vim.fn.matchlist
local v_stderr

----------------------------------------------------------------------
-- 1. ワーカー内パーサー (io.lines() ベース)
----------------------------------------------------------------------

local function strip_comments(text)
  text = text:gsub("/%*.-%*/", "")
  text = text:gsub("//[^\n]*", "")
  return text
end

-- [!] get_hash_from_lines 関数を削除

-- ▼▼▼ UCLASS/USTRUCT ブロックをパースするヘルパー関数 ▼▼▼
local function process_block(block_lines, keyword_to_find, macro_type)
    local block_text = table.concat(block_lines, "\n")
    local cleaned_text = strip_comments(block_text)
    local flattened_text = cleaned_text:gsub("[\n\r]", " "):gsub("%s+", " ")

    local vim_pattern
    if keyword_to_find == "struct" then
    -- struct FMyStruct : public FBaseStruct
    -- struct FMyStruct (継承なし)
      vim_pattern = [[.\{-}\(USTRUCT\)\s*(.\{-})\s*struct\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*\(:\s*\(public\|protected\|private\)\s*\(\w\+\)\)\?]]
    else -- class
      -- class AMyActor : public AActor
    vim_pattern = [[.\{-}\(UCLASS\|UINTERFACE\)\s*(.\{-})\s*class\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*:\s*\(public\|protected\|private\)\s*\(\w\+\)]]
    end
    -- ▲▲▲ 修正完了 ▲▲▲
    
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
-- ▲▲▲ ヘルパー関数ここまで ▲▲▲

-- [!] out_hash 引数を削除
local function parse_single_header_line_by_line(file_path)
  local file, err = io.open(file_path, "r")
  if not file then
    v_stderr:write(("[Worker] Failed to open file: %s (%s)\n"):format(file_path, tostring(err)))
    return nil -- classes
  end

  local final_classes = {}
  -- [!] all_lines_for_hash テーブルを削除
  
  local state = "SCANNING"
  local block_lines = {}
  local macro_type = nil
  local keyword_to_find = nil
  
  for line in file:lines() do
    -- [!] ハッシュ用の table.insert を削除

    if state == "SCANNING" then
        local is_uclass = line:find("UCLASS")
        local is_uinterface = line:find("UINTERFACE")
        local is_ustruct = line:find("USTRUCT")

        if is_uclass or is_uinterface or is_ustruct then
          state = "BLOCK_HUNTING"
          block_lines = { line }
          macro_type = is_uclass and "UCLASS" or (is_uinterface and "UINTERFACE" or "USTRUCT")
          keyword_to_find = (macro_type == "USTRUCT") and "struct" or "class"
          
          if line:find("_BODY") then
              local symbol_info = process_block(block_lines, keyword_to_find, macro_type)
              if symbol_info then table.insert(final_classes, symbol_info) end
              state = "SCANNING"
              block_lines = {}
          end
        end
    elseif state == "BLOCK_HUNTING" then
        table.insert(block_lines, line)
        
        if line:find("_BODY") then
            local symbol_info = process_block(block_lines, keyword_to_find, macro_type)
            if symbol_info then table.insert(final_classes, symbol_info) end
            state = "SCANNING"
            block_lines = {}
        end
    end
  end
  file:close()

  -- [!] ハッシュ計算 (out_hash[1] = ...) を削除
  
  if #final_classes > 0 then
    return final_classes
  else
    return nil
  end
end


----------------------------------------------------------------------
-- 2. ワーカー・メインロジック (ハッシュ計算なし)
----------------------------------------------------------------------
local function main()
  v_stderr = io.open(vim.api.nvim_eval("v:stderr"), "w")
  local raw_payload = io.read("*a")
  if not raw_payload or raw_payload == "" then
    v_stderr:write("[Worker] Error: Did not receive any payload from stdin.\n")
    vim.cmd("cquit!")
    return
  end
  
  local ok, payload = pcall(json_decode, raw_payload)
  if not ok or not payload or not payload.files then
    v_stderr:write("[Worker] Error: Failed to decode JSON payload or payload is invalid.\n")
    vim.cmd("cquit!")
    return
  end

  local files_to_parse = payload.files
  local mtimes_map = payload.mtimes
  -- [!] hashes_map は使わない
  
  for i, file_path in ipairs(files_to_parse) do
    local current_mtime = mtimes_map[file_path]
    
    if not current_mtime then
        v_stderr:write(("[Worker] Warning: Missing mtime for %s. Skipping.\n"):format(file_path))
    else
        local classes = parse_single_header_line_by_line(file_path)
        
        -- [!] 結果には classes のみ含める
        local result_for_file = {
            [file_path] = { classes = classes } -- mtime や hash は含めない
        }
        
        local output_ok, json_line = pcall(json_encode, result_for_file)
        if output_ok then
            io.write(json_line .. "\n")
        else
            v_stderr:write(("[Worker] Error: Failed to encode JSON line for %s\n"):format(file_path))
        end
    end
    
    if i % 50 == 0 or i == #files_to_parse or i == 1 then
        io.stdout:flush()
    end
  end
  
  v_stderr:close()
  vim.cmd("qall!")
end

main()
