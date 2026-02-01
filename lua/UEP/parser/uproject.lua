local M = {}

local parse_uproject = function(file_path)
  if not file_path or file_path == "" or vim.fn.filereadable(file_path) == 0 then
    return {}
  end
  local lines = vim.fn.readfile(file_path)
  if not lines then
    return {}
  end

  local result = {}

  local bufnr = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "json")
  if not ok or not parser then
    return result
  end

  local tree = parser:parse(true)[1]
  if not tree then
    return result
  end
  local tree_root = tree:root()

  result = {
    tree_root = tree_root,
    bufnr = bufnr,
  }

  return result
end

local cleanup_uproject = function(parsed_uproject)
  if parsed_uproject.bufnr and vim.api.nvim_buf_is_valid(parsed_uproject.bufnr) then
    vim.api.nvim_buf_delete(parsed_uproject.bufnr, { force = true })
  end
end

local check_root = function(root)
  if root:type() ~= "document" or root:child(0):type() ~= "object" then
    return false
  else
    return true
  end
end
-- (#eq? @obj.key "Modules") (#set! node_type "key")
local modules_query = function(module_name)
  return string.format(
    [[
( document
  ( object
    ( pair
      key: ( string
        ( string_content ) @obj.key (#eq? @obj.key "Modules")
      )
      value: (_) @obj.value
    )
  )
)
( document
  ( object
    ( pair
      key: ( string
        ( string_content ) @obj.key (#eq? @obj.key "Modules")
      )
      value: ( array
        ( object
          ( pair
            key: ( string
              ( string_content ) @module.key (#eq? @module.key "Name")
            )
            value: ( string
              ( string_content ) @module.value (#eq? @module.value "%s")
            )
          )
        )
      )
    )
  )
)
( document
  ( object
    ( pair
      key: ( string
        ( string_content ) @obj.key (#eq? @obj.key "Modules")
      )
      value: ( array
        ( object ) @last.module .
      )
    )
  )
)
( document
  ( object
    ( pair ) @last.entry .
  )
)
  ]],
    module_name
  )
end

function M.add_module(file_path, module_opts)
  local parsed_uproject = parse_uproject(file_path)
  if next(parsed_uproject) == nil then
    vim.notify("Could not parse file " .. file_path, "error")
    cleanup_uproject(parsed_uproject)
    return
  end
  if not check_root(parsed_uproject.tree_root) then
    vim.notify("Invalid uproject file '" .. vim.fs.basename(file_path) .. "'", "error")
    cleanup_uproject(parsed_uproject)
    return
  end

  local query = vim.treesitter.query.parse("json", modules_query(module_opts.module_name))
  local buf_lines = vim.api.nvim_buf_get_lines(parsed_uproject.bufnr, 0, -1, false)
  local modules_node
  local module_exists = false
  local last_node
  local last_entry
  local tabstop

  for pattern, match, _ in query:iter_matches(parsed_uproject.tree_root, parsed_uproject.bufnr, 0, -1) do
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      for _, node in ipairs(nodes) do
        if pattern == 1 and name == "obj.value" then
          modules_node = node
        elseif pattern == 2 and name == "module.value" then
          module_exists = true
        elseif pattern == 3 then
          if name == "last.module" then
            last_node = node
          end
        elseif pattern == 4 then
          if name == "last.entry" then
            local startr, startc, _, _ = node:range()
            tabstop = string.sub(buf_lines[startr + 1], 1, startc)
            last_entry = node
          end
        end
      end
    end
  end

  if module_exists then
    cleanup_uproject(parsed_uproject)
    return
  end

  if modules_node == nil then
    local _, _, endr, endc = last_entry:range()
    if string.len(buf_lines[endr + 1]) ~= endc then
      table.insert(
        buf_lines,
        endr + 2,
        string.sub(buf_lines[endr + 1], endc + 1, string.len(buf_lines[endr + 1]))
      )
    end
    buf_lines[endr + 1] = string.sub(buf_lines[endr + 1], 1, endc) .. ","
    table.insert(buf_lines, endr + 2, tabstop .. "]")
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "}")
    table.insert(
      buf_lines,
      endr + 2,
      string.rep(tabstop, 3) .. '"LoadingPhase": "' .. module_opts.loading_phase .. '"'
    )
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 3) .. '"Type": "' .. module_opts.module_type .. '",')
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 3) .. '"Name": "' .. module_opts.module_name .. '",')
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "{")
    table.insert(buf_lines, endr + 2, tabstop .. '"Modules": [')
  else
    local _, startc, endr, endc = last_node:range()
    if string.len(buf_lines[endr + 1]) ~= endc then
      table.insert(
        buf_lines,
        endr + 2,
        string.sub(buf_lines[endr + 1], endc + 1, string.len(buf_lines[endr + 1]))
      )
    end
    buf_lines[endr + 1] = string.sub(buf_lines[endr + 1], 1, endc) .. ","
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "}")
    table.insert(
      buf_lines,
      endr + 2,
      string.rep(tabstop, 3) .. '"LoadingPhase": "' .. module_opts.loading_phase .. '"'
    )
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 3) .. '"Type": "' .. module_opts.module_type .. '",')
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 3) .. '"Name": "' .. module_opts.module_name .. '",')
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "{")
  end
  vim.fn.writefile(vim.fn.readfile(file_path), file_path .. ".old")
  vim.fn.writefile(buf_lines, file_path)
  cleanup_uproject(parsed_uproject)
end

return M
