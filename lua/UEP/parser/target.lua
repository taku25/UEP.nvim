local M = {}

local parse_target = function(file_path)
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

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "c_sharp")
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

local cleanup_target = function(parsed_target)
  if parsed_target.bufnr and vim.api.nvim_buf_is_valid(parsed_target.bufnr) then
    vim.api.nvim_buf_delete(parsed_target.bufnr, { force = true })
  end
end

local get_tabstop = function(parsed_target)
  local query = vim.treesitter.query.parse(
    "c_sharp",
    [[
    ( compilation_unit
      ( class_declaration
        body: ( declaration_list
          ( constructor_declaration ) @constr.decl
        )
      )
    )
    ]]
  )
  local buf_lines = vim.api.nvim_buf_get_lines(parsed_target.bufnr, 0, -1, false)
  for _, match, _ in query:iter_matches(parsed_target.tree_root, parsed_target.bufnr, 0, -1) do
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      if name == "constr.decl" then
        for _, node in ipairs(nodes) do
          local startr, startc, _, _ = node:range()
          return string.sub(buf_lines[startr + 1], 1, startc)
        end
      end
    end
  end
end

local constructor_has_call = function(parsed_target)
  local query = vim.treesitter.query.parse(
    "c_sharp",
    [[
( compilation_unit
  ( class_declaration
    ( base_list
      ( identifier ) @class.base (#eq? @class.base "TargetRules")
    )
    body: ( declaration_list
      ( constructor_declaration
        body: ( block
          ( expression_statement
            ( invocation_expression
              function: ( identifier ) @nvim.call (#eq? @nvim.call "RegisterModulesCreatedByNeovim")
            )
          )
        )
      )
    )
  )
)
    ]]
  )
  for _, match, _ in query:iter_matches(parsed_target.tree_root, parsed_target.bufnr, 0, -1) do
    for id, _ in pairs(match) do
      local name = query.captures[id]
      if name == "nvim.call" then
        return true
      end
    end
  end
end

local constructor_last_expression = function(parsed_target)
  local query = vim.treesitter.query.parse(
    "c_sharp",
    [[
( compilation_unit
  ( class_declaration
    ( base_list
      ( identifier ) @class.base (#eq? @class.base "TargetRules")
    )
    body: (declaration_list
      ( constructor_declaration
        body: ( block
          (_) @constr.last .
        )
      )
    )
  )
)
    ]]
  )
  for _, match, _ in query:iter_matches(parsed_target.tree_root, parsed_target.bufnr, 0, -1) do
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      if name == "constr.last" then
        for _, node in ipairs(nodes) do
          return node
        end
      end
    end
  end
end

local method_declared = function(parsed_target, module_name)
  local result = {
    method_found = false,
    add_range_found = false,
    module_found = false,
    method_last_expr = nil,
    initializer_expr = nil,
    last_module = nil,
    last_decl = nil,
  }
  local query = vim.treesitter.query.parse(
    "c_sharp",
    string.format(
      [[
( compilation_unit
  ( class_declaration
    ( base_list
      ( identifier ) @class.base (#eq? @class.base "TargetRules")
    )
    body: (declaration_list
      ( method_declaration
        name: ( identifier ) @method.def (#eq? @method.def "RegisterModulesCreatedByNeovim")
        body: ( block
          [( expression_statement
            ( invocation_expression
              function: ( member_access_expression )? @add.range (#eq? @add.range "ExtraModuleNames.AddRange")
              arguments: ( argument_list
                ( argument
                  ( array_creation_expression
                    ( initializer_expression
                      ( string_literal )* @last.module .
                    ) @init.expr
                  )
                )
              )
            )
          )
          (_)]* @last.expr .
        )
      )
    )
  )
)
( compilation_unit
  ( class_declaration
    ( base_list
      ( identifier ) @class.base (#eq? @class.base "TargetRules")
    )
    body: (declaration_list
      [( method_declaration
        name: ( identifier ) @method.def (#eq? @method.def "RegisterModulesCreatedByNeovim")
        body: ( block
          [( expression_statement
            ( invocation_expression
              function: ( member_access_expression )? @add.range (#eq? @add.range "ExtraModuleNames.AddRange")
              arguments: ( argument_list
                ( argument
                  ( array_creation_expression
                    ( initializer_expression
                      ( string_literal
                        ( string_literal_content ) @module.found (#eq? @module.found "%s")
                      )
                    )
                  )
                )
              )
            )
          )
          (_)]* @last.expr .
        )
      )
      (_)]* @last.decl .
    )
  )
)
    ]],
      module_name
    )
  )
  for pattern, match, _ in query:iter_matches(parsed_target.tree_root, parsed_target.bufnr, 0, -1) do
    for id, nodes in pairs(match) do
      local name = query.captures[id]
      if pattern == 1 then
        if name == "method.def" then
          result.method_found = true
        elseif name == "add.range" then
          result.add_range_found = true
        elseif name == "last.expr" then
          for _, node in ipairs(nodes) do
            result.method_last_expr = node
          end
        elseif name == "init.expr" then
          for _, node in ipairs(nodes) do
            result.initializer_expr = node
          end
        elseif name == "last.module" then
          for _, node in ipairs(nodes) do
            result.last_module = node
          end
        end
      elseif pattern == 2 then
        if name == "module.found" then
          result.module_found = true
        elseif name == "last.decl" then
          for _, node in ipairs(nodes) do
            result.last_decl = node
          end
        end
      end
    end
  end
  return result
end

M.add_module = function(file_path, module_opts)
  local parsed_target = parse_target(file_path)
  if next(parsed_target) == nil then
    vim.notify("Could not parse file " .. file_path, "error")
    cleanup_target(parsed_target)
    return
  end

  local buf_lines = vim.api.nvim_buf_get_lines(parsed_target.bufnr, 0, -1, false)
  local tabstop = get_tabstop(parsed_target)
  local offset = 0

  if not constructor_has_call(parsed_target) then
    local constr_last_expr = constructor_last_expression(parsed_target)
    local _, _, endr, _ = constr_last_expr:range()
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "RegisterModulesCreatedByNeovim();")
    offset = offset + 1
  end

  local method_infos = method_declared(parsed_target, module_opts.module_name)
  if method_infos.method_found then
    if method_infos.add_range_found then
      if not method_infos.module_found then
        if method_infos.last_module ~= nil then
          local _, _, endr, endc = method_infos.last_module:range()
          endr = endr + offset
          if string.len(buf_lines[endr + 1]) ~= endc then
            table.insert(
              buf_lines,
              endr + 2,
              string.rep(tabstop, 3) .. string.sub(buf_lines[endr + 1], endc + 1, -1)
            )
            offset = offset + 1
          end
          buf_lines[endr + 1] = string.sub(buf_lines[endr + 1], 1, endc) .. ","
          table.insert(buf_lines, endr + 2, string.rep(tabstop, 3) .. '"' .. module_opts.module_name .. '"')
          offset = offset + 1
        else
          local _, _, endr_i, endc_i = method_infos.initializer_expr:child(0):range()
          local _, startc_f, endr_f, _ =
            method_infos.initializer_expr:child(method_infos.initializer_expr:child_count() - 1):range()
          endr_i = endr_i + offset
          endr_f = endr_f + offset
          if endr_i == endr_f then
            table.insert(
              buf_lines,
              endr_i + 2,
              string.rep(tabstop, 2) .. string.sub(buf_lines[endr_i + 1], startc_f + 1, -1)
            )
            buf_lines[endr_i + 1] = string.sub(buf_lines[endr_i + 1], 1, endc_i)
            table.insert(
              buf_lines,
              endr_i + 2,
              string.rep(tabstop, 3) .. '"' .. module_opts.module_name .. '"'
            )
          else
            table.insert(
              buf_lines,
              endr_f + 1,
              string.rep(tabstop, 3) .. '"' .. module_opts.module_name .. '"'
            )
          end
        end
      end
    else
      local _, _, endr, _ = method_infos.method_last_expr:range()
      endr = endr + offset
      table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "});")
      table.insert(buf_lines, endr + 2, string.rep(tabstop, 3) .. '"' .. module_opts.module_name .. '"')
      table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "ExtraModuleNames.AddRange(new string[] {")
      offset = offset + 3
    end
  else
    local _, _, endr, _ = method_infos.last_decl:range()
    endr = endr + offset
    table.insert(buf_lines, endr + 2, tabstop .. "}")
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "});")
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 3) .. '"' .. module_opts.module_name .. '"')
    table.insert(buf_lines, endr + 2, string.rep(tabstop, 2) .. "ExtraModuleNames.AddRange(new string[] {")
    table.insert(buf_lines, endr + 2, tabstop .. "{")
    table.insert(buf_lines, endr + 2, tabstop .. "private void RegisterModulesCreatedByNeovim()")
    offset = offset + 6
  end
  vim.fn.writefile(vim.fn.readfile(file_path), file_path .. ".old")
  vim.fn.writefile(buf_lines, file_path)
  cleanup_target(parsed_target)
end

return M
