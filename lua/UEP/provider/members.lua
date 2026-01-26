local uep_db = require("UEP.db.init")
local db_query = require("UEP.db.query")
local uep_log = require("UEP.logger").get()
local cpp_parser = nil -- 遅延ロード

local M = {}

-- オンデマンド解析で戻り値型を補完する
local function enrich_members_with_parser(db, class_name, members)
  local missing_return_type = false
  for _, m in ipairs(members) do
    if m.type == "function" and (not m.return_type or m.return_type == "") then
      missing_return_type = true
      break
    end
  end

  if not missing_return_type then return end

  -- 定義ファイルを取得
  local file_path = db_query.get_class_file_path(db, class_name)
  if not file_path or vim.fn.filereadable(file_path) == 0 then return end

  -- パーサーロード
  if not cpp_parser then
    local ok, p = pcall(require, "UNL.parser.cpp")
    if ok then cpp_parser = p else return end
  end

  -- パース実行 (同期)
  local result = cpp_parser.parse(file_path)
  if not result or not result.map then return end

  -- クラスデータを探す (UClassなどのプレフィックス考慮)
  local class_data = cpp_parser.find_best_match_class(result, class_name)
  if not class_data then return end

  -- メソッド情報をマッピングしてDB更新用データを準備
  local method_map = {}
  for _, access in ipairs({"public", "protected", "private"}) do
    if class_data.methods[access] then
      for _, m in ipairs(class_data.methods[access]) do
        method_map[m.name] = m
      end
    end
  end

  -- メンバーリストを更新 & DB保存
  db:eval("BEGIN TRANSACTION;")
  for _, m in ipairs(members) do
    if m.type == "function" and (not m.return_type or m.return_type == "") and m.class_name == class_name then
      local parsed_m = method_map[m.name]
      if parsed_m and parsed_m.return_type then
        m.return_type = parsed_m.return_type
        db_query.update_member_return_type(db, class_name, m.name, m.return_type)
      end
    end
  end
  db:eval("COMMIT;")
end

function M.request(opts, on_complete)
  opts = opts or {}
  local class_name = opts.class_name
  if not class_name or class_name == "" then 
      if on_complete then on_complete(true, {}) end
      return {} 
  end

  local db = uep_db.get()
  if not db then 
      if on_complete then on_complete(false, "DB not available") end
      return {} 
  end

  -- 再帰的に親クラスのメンバーも含めて取得
  local rows = db_query.get_class_members_recursive(db, class_name)
  
  if not rows or type(rows) ~= "table" then 
      rows = {} 
  end
  
  -- 2. オンデマンド解析 (リクエストされたクラス自身のみ)
  enrich_members_with_parser(db, class_name, rows)
  
  -- 3. Fallback logic (Detail string parsing)
  for _, row in ipairs(rows) do
      if (not row.return_type or row.return_type == "") and row.detail and row.detail ~= "" then
          local type_guess = row.detail:match("^%s*([A-Z]%w+)")
          if type_guess then
              row.return_type = type_guess
          end
      end
  end
  
  if on_complete then
      on_complete(true, rows)
  end
  
  return rows
end

return M