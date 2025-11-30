-- lua/UEP/cmd/core/refresh_target.lua
-- [!] キャッシュに path を含めるよう修正

local fs = require("vim.fs")
local uep_log = require("UEP.logger")

local M = {}

---
-- Target.cs ファイルを読み取り、ターゲット名とタイプを正規表現で抽出する
-- @param file_path string Target.cs ファイルへのフルパス
-- @return table|nil { name = "MyProjectEditor", type = "Editor", path = "..." }
local function parse_target_cs_file(file_path)
  local lines = vim.fn.readfile(file_path)
  if vim.v.shell_error ~= 0 or not lines then
    uep_log.get().warn("Target.cs parser: Could not read file: %s", file_path)
    return nil
  end

  local content = table.concat(lines, "\n")
  local flattened = content:gsub("[\r\n]", " ") -- 改行をスペースに置換

  -- "public [sealed] class [AnyName] : [AnyBase]"
  local name_match, base_class = flattened:match([[public%s+[%w_]*%s*class%s+([%w_]+)%s*:%s*([%w_]+)]])
  
  local type_match = flattened:match([[Type%s*=%s*TargetType%.([%w_]+);]])

  local final_name = nil
  local final_type = nil

  if name_match then
    final_name = name_match:gsub("Target$", "") 
  else
    uep_log.get().warn("Target.cs parser: Could not parse class name from: %s", file_path)
    return nil
  end
  
  if type_match then
    final_type = type_match
  elseif base_class then
    if base_class == "TestTargetRules" then
      final_type = "Program"
    elseif base_class:find("Rules$") then
      final_type = "Game" 
    else
      uep_log.get().trace("Target.cs parser: Guessing 'Program' type for %s", file_path)
      final_type = "Program"
    end
  else
    uep_log.get().warn("Target.cs parser: Could not parse type from: %s", file_path)
    return nil
  end

  -- ★修正: path を含める (フィルタリングと即時オープンのため必須)
  return { 
      name = final_name, 
      type = final_type, 
      path = file_path 
  }
end

---
-- 指定されたパスから *.Target.cs ファイルを非同期で検索し、パースする
function M.find_and_parse_targets_async(game_root, engine_root, on_complete)
  local log = uep_log.get()
  log.debug("Scanning for *.Target.cs files...")
  
  local target_cs_search_paths = {
    fs.joinpath(game_root, "Source"),
    fs.joinpath(engine_root, "Engine", "Source"),
    fs.joinpath(engine_root, "Engine", "Source", "Programs")
  }
  
  local fd_cmd_targets = { "fd", "--absolute-path", "--type", "f", "--path-separator", "/", "--glob", "*.Target.cs" }
  for _, spath in ipairs(target_cs_search_paths) do
      if vim.fn.isdirectory(spath) == 1 then
          table.insert(fd_cmd_targets, "--search-path")
          table.insert(fd_cmd_targets, spath)
      end
  end

  local all_target_cs_files = {}
  local target_fd_stderr = {}
  
  vim.fn.jobstart(fd_cmd_targets, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_target_cs_files, line) end end end
    end,
    on_stderr = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(target_fd_stderr, line) end end end
    end,
    on_exit = function(_, target_code)
      if target_code ~= 0 then
         log.error("fd command failed for Target.cs: %s", table.concat(target_fd_stderr, "\n"))
      end

      log.info("Found %d Target.cs files. Parsing...", #all_target_cs_files)
      
      local build_targets_list = {}
      local seen_targets = {}

      for _, cs_path in ipairs(all_target_cs_files) do
        local target_info = parse_target_cs_file(cs_path)
        
        if target_info then
          -- 名前とタイプの組み合わせで重複チェック
          local key = target_info.name .. "::" .. target_info.type
          if not seen_targets[key] then
            table.insert(build_targets_list, target_info)
            seen_targets[key] = true
          else
            log.trace("Skipping duplicate target: %s", key)
          end
        end
      end
      
      log.info("Finished parsing Target.cs. Found %d valid build targets.", #build_targets_list)
      
      if on_complete then
        on_complete(build_targets_list)
      end
    end,
  })
end

return M
