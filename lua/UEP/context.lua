-- lua/UEP/context.lua

local M = {}

local unl_context
local uep_finder

-- 現在のプロジェクトのハンドルを自動で取得する内部関数
local function get_current_project_handle()
  if not unl_context then unl_context = require("UNL.context") end
  if not uep_finder then uep_finder = require("UNL.finder.project") end
  
  local project_root = uep_finder.find_project_root(vim.loop.cwd())
  if not project_root then
    return nil
  end
  
  -- :key() を使用
  return unl_context.use("UEP"):key(project_root)
end

-- 現在のプロジェクトのオンメモリキャッシュに値を保存する
function M.set(key, value)
  local handle = get_current_project_handle()
  if handle then
    handle:set(key, value)
    return true
  end
  return false
end

-- 現在のプロジェクトのオンメモリキャッシュから値を取得する
function M.get(key)
  local handle = get_current_project_handle()
  if handle then
    return handle:get(key)
  end
  return nil
end

return M
