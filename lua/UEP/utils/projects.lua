-- lua/UEP/utils/dashboard.lua
local M = {}

--- プロジェクト一覧を取得し、最終アクセス順にソートして返す
--- @param opts? string|table オプション
---   - stringの場合: キャッシュフォルダ名として扱う (例: "UNL", "UEP")
---   - tableの場合: { name = "UEP" } のように指定
---   - 省略時: デフォルトの "UEP" フォルダを参照
--- @return table { { name="ProjectName", path="/path/to/root", icon="UE" }, ... }
function M.get_recent_projects(opts)
  -- 1. フォルダ名の決定
  local folder_name = "UEP" -- デフォルト

  if type(opts) == "string" then
    folder_name = opts
  elseif type(opts) == "table" and opts.name then
    folder_name = opts.name
  end

  -- 2. パスの構築 (stdpath("cache") / folder_name / projects.json)
  local std_cache = vim.fn.stdpath("cache")
  local cache_file_path = table.concat({ std_cache, folder_name, "projects.json" }, "/")
  
  -- ファイル区切り文字の正規化 (Windows対策)
  cache_file_path = cache_file_path:gsub("\\", "/")

  -- 3. ファイル読み込み (存在チェック)
  if vim.fn.filereadable(cache_file_path) == 0 then
    return {}
  end

  -- 4. JSONデコード
  local content = table.concat(vim.fn.readfile(cache_file_path), "\n")
  local ok, data = pcall(vim.json.decode, content)
  
  if not ok or not data or not data.projects then
    return {}
  end

  -- 5. リスト変換
  local projects_list = {}
  for display_name, meta in pairs(data.projects) do
    table.insert(projects_list, {
      name = display_name,
      path = vim.fn.fnamemodify(meta.uproject_path, ":h"), 
      last_indexed_at = meta.last_indexed_at or 0,
      engine = meta.engine_association or "Unknown"
    })
  end

  -- 6. ソート (新しい順)
  table.sort(projects_list, function(a, b)
    return a.last_indexed_at > b.last_indexed_at
  end)

  return projects_list
end

return M
