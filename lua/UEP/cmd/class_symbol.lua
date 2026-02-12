local derived_core = require("UEP.cmd.core.derived")
local unl_picker = require("UNL.picker")
local uep_config = require("UEP.config")
local uep_log = require("UEP.logger")
local unl_api = require("UNL.api")
local unl_buf_open = require("UNL.buf.open")

local M = {}

-- ============================================================
-- Helper: シンボルデータの整形
-- ============================================================

local function flatten_hierarchy(symbols)
  local flat_list = {}
  
  for _, item in ipairs(symbols) do
    table.insert(flat_list, item)

    if item.kind == "UClass" or item.kind == "Class" or 
       item.kind == "UStruct" or item.kind == "Struct" then
       
       if item.methods then
         for _, access in ipairs({"public", "protected", "private", "impl"}) do
           if item.methods[access] then
             for _, method in ipairs(item.methods[access]) do
               table.insert(flat_list, method)
             end
           end
         end
       end

       if item.fields then
         for _, access in ipairs({"public", "protected", "private", "impl"}) do
           if item.fields[access] then
             for _, field in ipairs(item.fields[access]) do
               table.insert(flat_list, field)
             end
           end
         end
       end
    end
  end
  return flat_list
end

local function show_symbol_picker(file_path, symbols)
  local flat_symbols = flatten_hierarchy(symbols)
  local items = {}
  
  for _, item in ipairs(flat_symbols) do
    local kind = item.kind or "Unknown"
    local kind_lower = kind:lower()
    local icon = " "
    
    if kind_lower:find("function") then icon = "󰊕 "
    elseif kind_lower:find("property") or kind_lower:find("field") then icon = " " 
    elseif kind_lower:find("class") or kind_lower:find("struct") then icon = "󰌗 " 
    elseif kind_lower:find("enum") then icon = "En " end

    table.insert(items, {
      display = string.format("%s %-35s  (%s)", icon, item.name, kind),
      value = item,
      filename = item.file_path,
      lnum = item.line,
      kind = kind,
    })
  end

  if #items == 0 then
    return vim.notify("No symbols found in selected class.", vim.log.levels.WARN)
  end

  unl_picker.open({
    kind = "uep_class_symbol_detail",
    title = "Symbols in " .. vim.fn.fnamemodify(file_path, ":t"),
    items = items,
    conf = uep_config.get(),
    preview_enabled = true,
    
    on_submit = function(selection)
      -- ★ここも同様に安全策
      local val = (selection and selection.value) or selection
      if val and val.file_path then -- item自体にfile_pathがある
        unl_buf_open.safe({ 
            file_path = val.file_path, 
            open_cmd = "edit", 
            plugin_name = "UEP" 
        })
        if val.line then
            vim.api.nvim_win_set_cursor(0, { val.line, 0 })
            vim.cmd("normal! zz")
        end
      end
    end
  })
end

-- ============================================================
-- Main Logic
-- ============================================================

function M.execute(opts)
  opts = opts or {}
  local log = uep_log.get()
  
  log.info("Fetching class list for symbol jump...")

  derived_core.get_all_classes({ 
      scope = opts.scope or "Full", 
      deps_flag = opts.deps_flag or "--deep-deps" 
  }, function(all_classes)
      
      if not all_classes or #all_classes == 0 then
          return vim.notify("No classes found.", vim.log.levels.WARN)
      end

      local items = {}
      for _, info in ipairs(all_classes) do
          table.insert(items, {
              display = string.format("%s (%s)", info.class_name, info.symbol_type or "Class"),
              value = info,
              filename = info.file_path,
              kind = "Class"
          })
      end

      unl_picker.open({
          kind = "uep_class_symbol",
          title = "Select Class to Find Symbols",
          items = items,
          conf = uep_config.get(),
          preview_enabled = true,
          
          on_submit = function(selection)
              if not selection then return end

              -- ★★★ 修正箇所: 値の取り出しを堅牢にする ★★★
              -- selection.value があればそれを、なければ selection 自体をデータとして扱う
              local class_info = selection.value or selection
              
              if not class_info or not class_info.file_path then
                  log.warn("Invalid selection structure. class_info is missing.")
                  return
              end

              local target_path = class_info.file_path
              log.debug("Requesting symbols for %s from UCM provider...", target_path)

              local ok, symbols = unl_api.provider.request("ucm.get_file_symbols", {
                  file_path = target_path
              })

              if ok and symbols then
                  show_symbol_picker(target_path, symbols)
              else
                  vim.notify("Failed to retrieve symbols from UCM. Is UCM.nvim installed?", vim.log.levels.ERROR)
              end
          end
      })
  end)
end

return M

