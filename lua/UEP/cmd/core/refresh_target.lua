-- lua/UEP/cmd/core/refresh_target.lua
-- [!] DatasmithMax* のような非標準的な .Target.cs ファイルに対応

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

  local content = table.concat(lines, "\n")
  local flattened = content:gsub("[\r\n]", " ") -- 改行をスペースに置換

  -- ▼▼▼ [修正 1] ▼▼▼
  -- "public class NameTarget : BaseRules" という厳格なパターンをやめ、
  -- "public class [AnyName] : [AnyBase]" という柔軟なパターンでマッチさせる
  local name_match, base_class = flattened:match([[public%s+class%s+([%w_]+)%s*:%s*([%w_]+)]])
  -- ▲▲▲ 修正 1 完了 ▲▲▲
  
  -- 2. ターゲットタイプを抽出 (変更なし)
  local type_match = flattened:match([[Type%s*=%s*TargetType%.([%w_]+);]])

  local final_name = nil
  local final_type = nil

  -- ▼▼▼ [修正 2] ▼▼▼
  -- 名前の処理 (正規表現が柔軟になったため、nil チェックが重要)
  if name_match then
    -- "Target" で終わっていれば削除する。終わっていなければ、そのまま
    final_name = name_match:gsub("Target$", "") 
  else
    -- 柔軟な正規表現でもマッチしなかった場合、ファイル形式が異なる
    uep_log.get().warn("Target.cs parser: Could not parse 'public class ... : ...' from: %s", file_path)
    return nil -- 名前が取れなければ失敗
  end
  
  -- タイプの処理 (ベースクラスの判定を強化)
  if type_match then
    -- Type = ... が明示的に指定されている場合
    final_type = type_match
  elseif base_class then
    -- Type がない場合、ベースクラスでデフォルトを決める
    if base_class == "TestTargetRules" then
      final_type = "Program"
    elseif base_class:find("Rules$") then
      -- "TargetRules" や "ModuleRules" (Build.cs) など、"Rules" で終わる
      -- .Target.cs ファイルなので "Game" (または "Editor") が妥当
      final_type = "Game" 
    else
      -- "Rules" で終わらないベースクラス (例: DatasmithTargetBase)
      -- これらは通常 "Program" ターゲット
      uep_log.get().trace("Target.cs parser: Base class '%s' does not end in 'Rules'. Guessing 'Program' type for %s", base_class, file_path)
      final_type = "Program"
    end
  else
    -- Type も base_class も見つからない（パース失敗）
    uep_log.get().warn("Target.cs parser: Could not parse type OR base class from: %s", file_path)
    return nil
  end
  -- ▲▲▲ 修正 2 完了 ▲▲▲

  -- 成功
  return { name = final_name, type = final_type }
end

---
-- 指定されたパスから *.Target.cs ファイルを非同期で検索し、パースする
-- (この関数自体には変更はありません)
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
      local seen_targets = {} -- 重複チェック用のテーブル

      for _, cs_path in ipairs(all_target_cs_files) do
        local target_info = parse_target_cs_file(cs_path)
        
        if target_info then
          -- name と type の組み合わせで重複をチェック
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
