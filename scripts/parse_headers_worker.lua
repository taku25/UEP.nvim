-- scripts/parse_headers_worker.lua (Treesitter + Regex Fallback)

local json_decode = vim.json.decode
local json_encode = vim.json.encode
local matchlist = vim.fn.matchlist

----------------------------------------------------------------------
-- 0. Setup Runtime Path for Treesitter
----------------------------------------------------------------------
local ts_rtp = vim.env.UEP_TS_RTP
if ts_rtp and ts_rtp ~= "" then
    for path in string.gmatch(ts_rtp, "([^,]+)") do
        vim.opt.runtimepath:append(path)
    end
end

----------------------------------------------------------------------
-- 1. Treesitter Parser
----------------------------------------------------------------------
local cpp_query = [[ 
  (class_specifier name: (_) @class_name) @class_def
  (struct_specifier name: (_) @struct_name) @struct_def
  (enum_specifier name: (_) @enum_name) @enum_def
  
  (unreal_class_declaration name: (_) @class_name) @uclass_def
  (unreal_struct_declaration name: (_) @struct_name) @ustruct_def
  (unreal_enum_declaration name: (_) @enum_name) @uenum_def
  
  (unreal_declare_class_macro) @declare_class_macro

  (unreal_function_declaration
    declarator: (_) @ufunc_declarator
  )
  (inline_method_definition
    (ufunction_macro)
    declarator: (_) @ufunc_declarator
  )
  (field_declaration
    (uproperty_macro)
    declarator: (_) @uprop_declarator
  )
]]

local function get_node_text(node, source)
    if not node then return nil end
    local ok, text = pcall(vim.treesitter.get_node_text, node, source)
    if ok then return text end
    return nil
end

local function has_body(node, content)
    if not node then return false end
    for child in node:iter_children() do
        if child:type() == "field_declaration_list" then return true end
        if child:type() == "enumerator_list" then return true end
    end
    local text = get_node_text(node, content)
    if text and (text:find("{ ") or text:find("GENERATED_BODY") or text:find("GENERATED_UCLASS_BODY")) then
        return true
    end
    return false
end

local function parse_header_with_ts(content)
    local ok, parser = pcall(vim.treesitter.get_string_parser, content, "cpp")
    if not ok or not parser then return nil end
    
    local tree = parser:parse()[1]
    if not tree then return nil end
    local root = tree:root()
    
    local ok_query, query = pcall(vim.treesitter.query.parse, "cpp", cpp_query)
    if not ok_query or not query then return nil end
    
    local classes_list = {}
    local members_list = {}
    
    for id, node, _ in query:iter_captures(root, content, 0, -1) do
        local capture_name = query.captures[id]
        local start_row, start_col, end_row, end_col = node:range()
        
        if capture_name == "declare_class_macro" then
             local text = get_node_text(node, content)
             if text then
                 local class_name, parent_name = text:match("DECLARE_CLASS%s*%(%s*([%w_]+)%s*,%s*([%w_]+)")
                 if class_name and parent_name then
                     local base_class_val = parent_name
                     if class_name == parent_name or parent_name == "None" then base_class_val = nil end
                     table.insert(classes_list, {
                         class_name = class_name, base_class = base_class_val,
                         is_final = false, is_interface = false, symbol_type = "class",
                         line = start_row + 1, range = {start_row, start_col, end_row, end_col}, members = {}
                     })
                 end
             end

        elseif capture_name == "class_name" or capture_name == "struct_name" or capture_name == "enum_name" then
            local parent = node:parent()
            if has_body(parent, content) then
                local type = parent:type()
                local text = get_node_text(node, content)
                
                if text and text ~= "" then
                    local brace_idx = text:find("{ ")
                    if brace_idx then text = text:sub(1, brace_idx - 1) end
                    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                    
                    if text ~= "" and text ~= ";" then
                        local symbol_type = "class"
                        local is_interface = false
                        local is_final = false
                        if capture_name == "struct_name" then symbol_type = "struct" end
                        if capture_name == "enum_name" then symbol_type = "enum"; is_final = true end
                        if type == "unreal_class_declaration" then symbol_type = "UCLASS" end
                        if type == "unreal_struct_declaration" then symbol_type = "USTRUCT" end
                        if type == "unreal_enum_declaration" then symbol_type = "UENUM"; is_final = true end
                        
                        local base_class = nil
                        for child in parent:iter_children() do
                            if child:type() == "base_class_clause" then
                                for i = 0, child:named_child_count() - 1 do
                                    local base_node = child:named_child(i)
                                    if base_node:type() ~= "access_specifier" and base_node:type() ~= "virtual" then
                                        base_class = get_node_text(base_node, content)
                                        break 
                                    end
                                end
                            end
                        end
                        if base_class == "UInterface" then is_interface = true end
                        local p_start, p_sc, p_end, p_ec = parent:range()
                        table.insert(classes_list, {
                            class_name = text, base_class = base_class, is_final = is_final, is_interface = is_interface, symbol_type = symbol_type,
                            line = start_row + 1, range = {p_start, p_sc, p_end, p_ec}, members = {}
                        })
                    end
                end
            end
            
        elseif capture_name == "ufunc_declarator" or capture_name == "uprop_declarator" then
            local raw_text = get_node_text(node, content)
            if raw_text then
                local name = raw_text
                
                if capture_name == "ufunc_declarator" then
                    -- Remove arguments: "Func(Arg)" -> "Func"
                    local paren_idx = name:find("%(")
                    if paren_idx then name = name:sub(1, paren_idx - 1) end
                else
                    -- Remove array: "Prop[10]" -> "Prop"
                    local bracket_idx = name:find("%[")
                    if bracket_idx then name = name:sub(1, bracket_idx - 1) end
                    -- Remove initialization: "Prop = Val" -> "Prop"
                    local eq_idx = name:find("=")
                    if eq_idx then name = name:sub(1, eq_idx - 1) end
                end
                
                -- Clean leading pointers/refs and spaces
                -- Note: This is heuristic. Real parsing needs AST traversal inside declarator.
                name = name:gsub("^[%s*&]+", ""):gsub("%s+$", "")
                -- If multiple words (e.g. "virtual void Func"), take the last one
                -- Actually declarator shouldn't contain return type "void", but "declarator: (_)" captures the whole node which MIGHT be function_declarator.
                -- In tree-sitter-c/cpp, function_declarator contains parameters.
                
                -- Better heuristic: Last word before '(' or end
                local last_word = name:match("(%w+)$")
                if last_word then name = last_word end
                
                local flags = (capture_name == "ufunc_declarator") and "UFUNCTION" or "UPROPERTY"
                local mem_type = (capture_name == "ufunc_declarator") and "function" or "property"
                
                -- Try to find 'virtual' in parent (declaration) text
                local decl_node = node:parent()
                if decl_node then
                    local decl_text = get_node_text(decl_node, content)
                    if decl_text and decl_text:find("virtual") then
                        flags = flags .. " virtual"
                    end
                end
                
                if name ~= "" and name ~= "virtual" then
                    -- Use definition/declaration node for range to ensure it falls within class
                    local range_node = decl_node or node
                    local m_s, m_sc, m_e, m_ec = range_node:range()
                    
                    table.insert(members_list, { 
                        name = name, type = mem_type, flags = flags, 
                        range = {m_s, m_sc, m_e, m_ec} 
                    })
                end
            end
        end
    end
    
    -- Assign members to classes based on range containment
    for _, member in ipairs(members_list) do
        local best_class = nil
        local min_size = 999999999
        for _, cls in ipairs(classes_list) do
            if member.range[1] >= cls.range[1] and member.range[3] <= cls.range[3] then
                local size = cls.range[3] - cls.range[1]
                if size < min_size then min_size = size; best_class = cls end
            end
        end
        if best_class then table.insert(best_class.members, member) end
    end
    
    -- Cleanup
    for _, cls in ipairs(classes_list) do cls.range = nil; for _, m in ipairs(cls.members) do m.range = nil end end
    
    if #classes_list > 0 then return classes_list end
    return nil
end

----------------------------------------------------------------------
-- 2. Regex Parser (Fallback)
----------------------------------------------------------------------

local function strip_comments(text)
  text = text:gsub("/%*.-%*/", "")
  text = text:gsub("//[^\n]*", "")
  return text
end

local function process_class_struct_block(block_text, keyword_to_find, macro_type)
    local cleaned_text = strip_comments(block_text)
    local flattened_text = cleaned_text:gsub("[\n\r]", " "):gsub("%s+", " ")

    local vim_pattern
    if keyword_to_find == "struct" then
      vim_pattern = [[.\{-}\(USTRUCT\)\s*(.\{-})\s*struct\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*\(:\s*\(public\|protected\|private\)\s*\(\w\+\)\)\?]]
    else 
      vim_pattern = [[.\{-}\(UCLASS\|UINTERFACE\)\s*(.\{-})\s*class\s\+\(\w\+_API\s\+\)\?\(\w\+\)\s*\(:\s*\(public\|protected\|private\)\s*\(\w\+\)\)\?]]
    end
    
    local result = matchlist(flattened_text, vim_pattern)

    if result and #result > 0 and result[4] and result[4] ~= "" then
      local symbol_name = result[4]
      local parent_symbol = nil
      if result[7] and result[7] ~= "" then
        parent_symbol = result[7]
      end
      
      local is_interface = (macro_type == "UINTERFACE") or (parent_symbol == "UInterface")

      return {
        class_name = symbol_name, 
        base_class = parent_symbol,
        is_final = false, 
        is_interface = is_interface, 
        symbol_type = keyword_to_find,
      }
    end
    return nil
end

local function process_enum_block(block_text, macro_type)
  local cleaned_text = strip_comments(block_text)
  local flattened_text = cleaned_text:gsub("[\n\r]", " "):gsub("%s+", " ")

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

local function parse_header_regex(content_lines)
  local final_symbols = {}
  local state = "SCANNING"
  local block_lines = {}
  local macro_type = nil
  local keyword_to_find = nil
  local start_line_num = 1
  
  -- メンバー追加用：現在アクティブなクラス
  local current_class = nil
  
  for line_idx, line in ipairs(content_lines) do
    if state == "SCANNING" then
        local is_uclass = line:find("UCLASS")
        local is_uinterface = line:find("UINTERFACE")
        local is_ustruct = line:find("USTRUCT")
        local is_uenum = line:find("UENUM")
        
        -- Member detection (UFUNCTION/UPROPERTY)
        -- クラスの中にいると仮定（厳密なスコープ管理はRegexでは困難なので、直近のクラスに追加する）
        if current_class then
            local is_ufunc = line:find("UFUNCTION")
            local is_uprop = line:find("UPROPERTY")
            
            if is_ufunc or is_uprop then
                -- 次の行（あるいはその次）を簡易チェックして名前を取得
                -- 行継続 (\) や複数行マクロには対応しきれないが、基本的なケースをカバー
                local next_line = content_lines[line_idx + 1]
                if next_line then
                    local name = nil
                    local mem_type = "variable"
                    local flags = is_ufunc and "UFUNCTION" or "UPROPERTY"
                    
                    if is_ufunc then
                        mem_type = "function"
                        -- virtual void FuncName(...)
                        -- void FuncName(...)
                        -- static int32 FuncName(...)
                        -- 戻り値の後の単語、かつ '(' の前
                        name = next_line:match("[%w_]+%s+([%w_]+)%s*%(%)") 
                        if not name then
                             -- 行頭から関数名っぽいものを探す (Constructorなど)
                             name = next_line:match("^%s*([%w_]+)%s*%(%)")
                        end
                    else
                        mem_type = "property"
                        -- Type VarName;
                        name = next_line:match("[%w_]+%s+([%w_]+)%s*[;=%[]")
                    end
                    
                    if name and name ~= "virtual" and name ~= "static" and name ~= "const" and name ~= "void" then
                        table.insert(current_class.members, {
                            name = name,
                            type = mem_type,
                            flags = flags,
                            -- regex mode doesn't support accurate range, use line number
                            range = {line_idx, 0, line_idx+1, 0}
                        })
                    end
                end
            end
        end

        if is_uclass or is_uinterface or is_ustruct then
          state = "HUNTING_BODY_MACRO"
          block_lines = { line }
          start_line_num = line_idx
          macro_type = is_uclass and "UCLASS" or (is_uinterface and "UINTERFACE" or "USTRUCT")
          keyword_to_find = (macro_type == "USTRUCT") and "struct" or "class"
          
          if line:find("_BODY") then
            local symbol_info = process_class_struct_block(table.concat(block_lines, "\n"), keyword_to_find, macro_type)
            if symbol_info then 
                symbol_info.line = start_line_num
                symbol_info.members = {} -- Initialize members
                table.insert(final_symbols, symbol_info)
                current_class = symbol_info -- Set active class
            end
            state = "SCANNING"
            block_lines = {}
          end
        elseif is_uenum then
          state = "HUNTING_ENUM_END"
          block_lines = { line }
          start_line_num = line_idx
          macro_type = "UENUM"
        
        else
          local declare_match = line:match("DECLARE_CLASS%s*%(%s*([%w_]+)%s*,%s*([%w_]+)")
          if declare_match then
             local class_name, parent_name = line:match("DECLARE_CLASS%s*%(%s*([%w_]+)%s*,%s*([%w_]+)")
             if class_name and parent_name then
                 local base_class_val = parent_name
                 if class_name == parent_name or parent_name == "None" then base_class_val = nil end
                 local cls = {
                     class_name = class_name, base_class = base_class_val,
                     is_final = false, is_interface = false, symbol_type = "class",
                     line = line_idx, members = {}
                 }
                 table.insert(final_symbols, cls)
                 current_class = cls
             end
          end
        end

    elseif state == "HUNTING_BODY_MACRO" then
        table.insert(block_lines, line)
        if line:find("_BODY") then
          local symbol_info = process_class_struct_block(table.concat(block_lines, "\n"), keyword_to_find, macro_type)
          if symbol_info then 
              symbol_info.line = start_line_num
              symbol_info.members = {}
              table.insert(final_symbols, symbol_info)
              current_class = symbol_info
          end
          state = "SCANNING"
          block_lines = {}
        end

    elseif state == "HUNTING_ENUM_END" then
        table.insert(block_lines, line)
        if line:find("};") then 
            local symbol_info = process_enum_block(table.concat(block_lines, "\n"), macro_type)
            if symbol_info then 
                symbol_info.line = start_line_num
                table.insert(final_symbols, symbol_info)
                -- Enum doesn't have members in this context
            end
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

----------------------------------------------------------------------
-- 3. Main Loop
----------------------------------------------------------------------
local function main()
  -- Restore production behavior (read from stdin)
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
        io.stderr:write(('[Worker] Warning: Missing mtime for %s. Skipping.\n'):format(file_path))
        goto continue_loop
    end

    local read_ok, lines = pcall(vim.fn.readfile, file_path)
    if not read_ok or not lines then
      io.stderr:write(('[Worker] Error: Could not read file %s\n'):format(file_path))
      goto continue_loop
    end
    
    local content = table.concat(lines, "\n")
    local new_hash = vim.fn.sha256(content)
    
    local result_for_file

    if old_hash and old_hash == new_hash then
        result_for_file = {
            path = file_path,
            status = "cache_hit",
            mtime = current_mtime
        }
    else
        -- Try Treesitter first
        local classes = parse_header_with_ts(content)
        local parser_used = "treesitter"
        
        if not classes then
             classes = parse_header_regex(lines)
             parser_used = "regex"
        end
        
        result_for_file = {
            path = file_path,
            status = "parsed",
            mtime = current_mtime,
            data = {
                classes = classes,
                new_hash = new_hash,
                parser = parser_used
            }
        }
    end
    
    local output_ok, json_line = pcall(json_encode, result_for_file)
    if output_ok then
        io.write(json_line .. "\n")
    else
        io.stderr:write(('[Worker] Error: Failed to encode JSON line for %s\n'):format(file_path))
    end
    
    if i % 50 == 0 or i == #files_data_list or i == 1 then
        io.stdout:flush()
    end
    
    ::continue_loop::
  end
   pcall(io.stdout.flush) 

  vim.cmd("qall!")
end

main()
