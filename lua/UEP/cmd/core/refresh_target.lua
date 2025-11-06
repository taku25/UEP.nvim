-- lua/UEP/cmd/core/refresh_target.lua
-- Target.cs ファイルのスキャンと解析を担当するモジュール

local fs = require("vim.fs")
local uep_log = require("UEP.logger")

local M = {}

---
-- Target.cs ファイルを読み取り、ターゲット名とタイプを正規表現で抽出する
-- @param file_path string Target.cs ファイルへのフルパス
-- @return table|nil { name = "MyProjectEditor", type = "Editor" } または nil
local function parse_target_cs_file(file_path)
  local lines = vim.fn.readfile(file_path)
  if vim.v.shell_error ~= 0 or not lines then
    uep_log.get().warn("Target.cs parser: Could not read file: %s", file_path)
    return nil
  end

  -- [!] ユーザーがテスト成功した正規表現ロジックを使用
  local content = table.concat(lines, "\n")
  local flattened = content:gsub("[\r\n]", " ") -- 改行をスペースに置換

  -- 1. ターゲット名とベースクラスを抽出
  local name_match, base_class = flattened:match([[public%s+class%s+([%w_]+Target)%s*:%s*([%w_]+Rules)]])
  -- 2. ターゲットタイプを抽出
  local type_match = flattened:match([[Type%s*=%s*TargetType%.([%w_]+);]])

  local final_name = nil
  local final_type = nil

  -- 名前の処理
  if name_match then
    final_name = name_match:gsub("Target$", "")
  else
    uep_log.get().warn("Target.cs parser: Could not parse name from: %s", file_path)
    return nil -- 名前が取れなければ失敗
  end
  
  -- タイプの処理
  if type_match then
    -- Type = ... が明示的に指定されている場合
    final_type = type_match
  elseif base_class then
    -- Type がない場合、ベースクラスでデフォルトを決める
    if base_class == "TestTargetRules" then
      final_type = "Program"
    else
      -- "TargetRules" またはその他
      final_type = "Game"
    end
  else
    -- Type も base_class も見つからない（パース失敗）
    uep_log.get().warn("Target.cs parser: Could not parse type OR base class from: %s", file_path)
    return nil
  end

  -- 成功
  return { name = final_name, type = final_type }
end

---
-- 指定されたパスから *.Target.cs ファイルを非同期で検索し、パースする
-- @param game_root string
-- @param engine_root string
-- @param on_complete function(build_targets_list table)
function M.find_and_parse_targets_async(game_root, engine_root, on_complete)
  local log = uep_log.get()
  log.debug("Scanning for *.Target.cs files...")
  
  local target_cs_search_paths = {
    fs.joinpath(game_root, "Source"),                -- 1. [ProjectRoot]/Source/
    fs.joinpath(engine_root, "Engine", "Source"),    -- 2. [EngineRoot]/Engine/Source/
    fs.joinpath(engine_root, "Engine", "Source", "Programs") -- 3. [EngineRoot]/Engine/Source/Programs/
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
  
  -- Target.cs 検索ジョブを開始
  vim.fn.jobstart(fd_cmd_targets, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(all_target_cs_files, line) end end end
    end,
    on_stderr = function(_, data)
      if data then for _, line in ipairs(data) do if line ~= "" then table.insert(target_fd_stderr, line) end end end
    end,
    on_exit = function(_, target_code) -- Target.cs 検索の on_exit
      if target_code ~= 0 then
         log.error("fd command failed for Target.cs: %s", table.concat(target_fd_stderr, "\n"))
      end

      log.info("Found %d Target.cs files. Parsing...", #all_target_cs_files)
      
      -- 見つかった Target.cs をパースする
      local build_targets_list = {}
      local seen_targets = {} -- ★ 重複チェック用のテーブルを追加

      for _, cs_path in ipairs(all_target_cs_files) do
        local target_info = parse_target_cs_file(cs_path)
        
        if target_info then
          -- ★ name と type の組み合わせで重複をチェック
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
      
      -- パース結果（空の場合も含む）をコールバックで返す
      if on_complete then
        on_complete(build_targets_list)
      end
    end,
  })
end

return M
