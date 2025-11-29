-- lua/UEP/cmd/web_doc.lua

local uep_log = require("UEP.logger")
local derived_core = require("UEP.cmd.core.derived")
local core_utils = require("UEP.cmd.core.utils")
local unl_picker = require("UNL.backend.picker")
local uep_config = require("UEP.config")
local fs = require("vim.fs")

local M = {}

local BASE_URL = "https://dev.epicgames.com/documentation/en-us/unreal-engine/API/"

-- (open_url, search_fallback, get_engine_version_string は変更なし)
local function open_url(url)
  if vim.ui and vim.ui.open then vim.ui.open(url); return end
  local cmd
  if vim.fn.has("mac") == 1 then cmd = { "open", url }
  elseif vim.fn.has("win32") == 1 then cmd = { "cmd.exe", "/c", "start", '""', url }
  else cmd = { "xdg-open", url } end
  vim.fn.jobstart(cmd, { detach = true })
end

local function search_fallback(query, version_str)
  local site_filter = "site:dev.epicgames.com/documentation/en-us/unreal-engine/API"
  local search_query = "\\ " .. site_filter .. " " .. query
  local encoded = vim.uri_encode(search_query)
  local final_url = "https://duckduckgo.com/?q=" .. encoded
  uep_log.get().info("Opening search fallback for: %s", query)
  open_url(final_url)
end

local function get_engine_version_string(engine_root)
  if not engine_root then return nil end
  local version_file = fs.joinpath(engine_root, "Engine", "Build", "Build.version")
  if vim.fn.filereadable(version_file) == 0 then return nil end
  local ok, content = pcall(vim.fn.readfile, version_file)
  if not ok then return nil end
  local decode_ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
  if decode_ok and data and data.MajorVersion and data.MinorVersion then
    return string.format("%d.%d", data.MajorVersion, data.MinorVersion)
  end
  return nil
end

-- ★修正: URLパス推測ロジックの改善
local function guess_doc_path(file_path)
  local normalized = file_path:gsub("\\", "/")
  
  -- 1. Runtime / Developer / Editor モジュール
  -- パターン: .../Engine/Source/(Runtime|Developer|Editor)/{ModuleName}/...
  local category, mod_name = normalized:match("/Engine/Source/(%w+)/([^/]+)/")
  if category and mod_name then 
    return string.format("%s/%s", category, mod_name) 
  end
  
  -- 2. Plugins
  -- 修正前: "/Engine/Plugins/(.+)/Source/" -> "FX/Niagara" (FXが含まれてしまう)
  -- 修正後: "/Source/" の直前にあるディレクトリ名（＝プラグイン名）だけを取得する
  -- 例: .../Plugins/FX/Niagara/Source/... -> "Niagara"
  if normalized:find("/Plugins/") then
      local plugin_name = normalized:match("/([^/]+)/Source/")
      if plugin_name then
         return "Plugins/" .. plugin_name
      end
  end
  
  return nil
end

local function resolve_and_open(query_class_name)
  local log = uep_log.get()
  core_utils.get_project_maps(vim.loop.cwd(), function(ok, maps)
    local engine_root = (ok and maps.engine_root) or nil
    local version_str = get_engine_version_string(engine_root)

    derived_core.get_all_classes({ scope = "Full" }, function(all_symbols)
      local target_file = nil
      local final_query = query_class_name

      if all_symbols then
        for _, info in ipairs(all_symbols) do
          if info.class_name == query_class_name then
            target_file = info.file_path; break
          end
          if info.class_name:sub(2) == query_class_name then
             target_file = info.file_path; final_query = info.class_name; break
          end
        end
      end

      if target_file then
         local doc_path = guess_doc_path(target_file)
         if doc_path then
            local url = BASE_URL .. doc_path .. "/" .. final_query
            if version_str then url = url .. "?application_version=" .. version_str end
            log.info("Direct documentation link: %s", url)
            open_url(url)
            return
         end
      end
      search_fallback(final_query, version_str)
    end)
  end)
end

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()

  if opts.has_bang then
    derived_core.get_all_classes({ scope = "Full" }, function(all_classes)
      if not all_classes or #all_classes == 0 then
        return log.error("No classes found. Please run :UEP refresh.")
      end
      local items = {}
      for _, info in ipairs(all_classes) do
        table.insert(items, {
          display = string.format("%s (%s)", info.class_name, info.symbol_type),
          value = info.class_name,
          filename = info.file_path,
          kind = info.symbol_type
        })
      end
      unl_picker.pick({
        kind = "uep_web_doc",
        title = "Select Class to Open Web Doc",
        items = items,
        conf = uep_config.get(),
        preview_enabled = true,
        on_submit = function(class_name)
          if class_name then resolve_and_open(class_name) end
        end,
      })
    end)
    return
  end

  local query = opts.query
  if not query or query == "" then query = vim.fn.expand("<cword>") end
  if not query or query == "" then return log.warn("No word found to search.") end
  log.info("Searching Web Doc for: %s", query)
  resolve_and_open(query)
end

return M
