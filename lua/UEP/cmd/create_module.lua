local log = require("UEP.logger")
local unl_api = require("UNL.api")
local unl_picker = require("UNL.backend.picker")
local unl_checker_picker = require("UNL.backend.checker_picker")
local uep_finder = require("UNL.finder.project")
local target_parser = require("UEP.parser.target")
local uproject_parser = require("UEP.parser.uproject")

local M = {}

function M.execute(opts)
  opts = opts or {}

  local function prepare_items(items)
    local ret = {}
    for _, item in ipairs(items) do
      table.insert(ret, {
        value = item,
        display = item,
        text = item,
      })
    end
    return ret
  end

  -- Add the module to the uproject or upligin file
  local find_and_edit_uproject = function(module_path, module_opts)
    local project_root = uep_finder.find_project_root(vim.loop.cwd())
    if project_root == nil then
      vim.notify("Could not find root of the UE project", "error")
      return
    end
    for dir in vim.fs.parents(module_path) do
      for name, type in vim.fs.dir(dir) do
        if
          type == "file" and (name:sub(-#".uproject") == ".uproject" or name:sub(-#".uplugin") == ".uplugin")
        then
          uproject_parser.add_module(vim.fs.joinpath(dir, name), module_opts)
          return
        end
      end
      if dir == project_root then
        return
      end
    end
  end

  -- Apply the modification to the project
  local create_module = function(module_opts)
    local project_root = uep_finder.find_project_root(vim.loop.cwd())
    if project_root == nil then
      vim.notify("Could not find root of the UE project", "error")
      return
    end

    vim.print("name: " .. module_opts.module_name)
    vim.print("path: " .. module_opts.subdir_path)
    vim.print("type: " .. module_opts.module_type)
    vim.print("loading phase: " .. module_opts.loading_phase)
    vim.print("targets: " .. table.concat(module_opts.targets, ", "))

    -- -- Modify the provided targets
    -- for _, target in ipairs(module_opts.targets) do
    -- 	target_parser.add_module(vim.fs.joinpath(project_root, target), module_opts)
    -- end
    --
    -- -- Create the folder for the module
    -- vim.fn.mkdir(vim.fs.joinpath(project_root, module_opts.subdir_path, module_opts.module_name), "p")
    -- vim.fn.mkdir(vim.fs.joinpath(project_root, module_opts.subdir_path, module_opts.module_name, "Public"), "p")
    -- vim.fn.mkdir(vim.fs.joinpath(project_root, module_opts.subdir_path, module_opts.module_name, "Private"), "p")
    -- local plugin_dir =
    -- 	vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(string.sub(debug.getinfo(1).source, 2, -1)))))
    --
    -- -- Get the default value for indentation
    -- local tab
    -- if vim.opt.expandtab._value then
    -- 	tab = string.rep(" ", vim.opt.tabstop._value)
    -- else
    -- 	tab = "\t"
    -- end
    --
    -- -- Create the module's .h file
    -- local lines = vim.fn.readfile(vim.fs.joinpath(plugin_dir, "templates", "Module.h.template"))
    -- local lines_sub = {}
    -- for _, line in ipairs(lines) do
    -- 	local line_sub, _ = line:gsub("<tab>", tab):gsub("<ModuleName>", module_opts.module_name)
    -- 	table.insert(lines_sub, line_sub)
    -- end
    -- vim.fn.writefile(
    -- 	lines_sub,
    -- 	vim.fs.joinpath(
    -- 		project_root,
    -- 		module_opts.subdir_path,
    -- 		module_opts.module_name,
    -- 		"Public",
    -- 		module_opts.module_name .. ".h"
    -- 	)
    -- )
    --
    -- -- Create the module's .cpp file
    -- lines = vim.fn.readfile(vim.fs.joinpath(plugin_dir, "templates", "Module.cpp.template"))
    -- lines_sub = {}
    -- for _, line in ipairs(lines) do
    -- 	local line_sub, _ = line:gsub("<tab>", tab):gsub("<ModuleName>", module_opts.module_name)
    -- 	table.insert(lines_sub, line_sub)
    -- end
    -- vim.fn.writefile(
    -- 	lines_sub,
    -- 	vim.fs.joinpath(
    -- 		project_root,
    -- 		module_opts.subdir_path,
    -- 		module_opts.module_name,
    -- 		"Private",
    -- 		module_opts.module_name .. ".cpp"
    -- 	)
    -- )
    --
    -- -- Create the module's Build.cs file
    -- lines = vim.fn.readfile(vim.fs.joinpath(plugin_dir, "templates", "Build.cs.template"))
    -- lines_sub = {}
    -- for _, line in ipairs(lines) do
    -- 	local line_sub, _ = line:gsub("<tab>", tab):gsub("<ModuleName>", module_opts.module_name)
    -- 	table.insert(lines_sub, line_sub)
    -- end
    -- vim.fn.writefile(
    -- 	lines_sub,
    -- 	vim.fs.joinpath(
    -- 		project_root,
    -- 		module_opts.subdir_path,
    -- 		module_opts.module_name,
    -- 		module_opts.module_name .. ".Build.cs"
    -- 	)
    -- )
    --
    -- -- Modify the uplugin or uproject file
    -- find_and_edit_uproject(
    -- 	vim.fs.joinpath(project_root, module_opts.subdir_path, module_opts.module_name),
    -- 	module_opts
    -- )
  end

  local function handle_targets(targets_opts)
    local project_root = uep_finder.find_project_root(vim.loop.cwd())
    if project_root == nil then
      vim.notify("Could not find root of the UE project", "error")
      return
    end
    -- Look for all the Target.cs in the hierachy and find if it is a uproject or uplgin
    local available_targets = {}
    local targets = targets_opts.targets or nil
    if targets ~= nil and #targets == 1 and targets[1] == "none" then
      targets = {}
    end
    local is_uproject = nil
    for dir in vim.fs.parents(vim.fs.joinpath(project_root, targets_opts.subdir_path, targets_opts.module_name)) do
      for name, type in vim.fs.dir(dir) do
        if type == "file" and name:sub(-#".Target.cs") == ".Target.cs" then
          table.insert(available_targets, vim.fs.relpath(project_root, vim.fs.joinpath(dir, name)))
        elseif is_uproject == nil and type == "file" and name:sub(-#".uproject") == ".uproject" then
          is_uproject = true
        elseif is_uproject == nil and type == "file" and name:sub(-#".uplugin") == ".uplugin" then
          is_uproject = false
        end
      end
      if dir == project_root then
        break
      end
    end

    for _, targ in ipairs(targets) do
      local found = false
      for _, avail_targ in ipairs(available_targets) do
        if targ == avail_targ then
          found = true
          break
        end
      end
      if not found then
        vim.notify(targ .. " is not in the available_targets.", "error")
        return
      end
    end
    if is_uproject == nil then
      vim.notify("Could not find a 'uproject' or 'uplugin'. Aborting.", "error")
      return
    elseif is_uproject then
      if targets == nil then
        unl_checker_picker.pick({
          kind = "targets_picker",
          title = "  Targets",
          conf = require("UNL.config").get("UEP"),
          items = prepare_items(available_targets),
          logger_name = "UEP",
          preview_enabled = false,
          default_check = true,
          multi_check = true,
          on_submit = function(selected)
            targets_opts.targets = selected
            create_module(targets_opts)
          end,
        })
      else
        targets_opts.targets = targets
        create_module(targets_opts)
      end
    else
      targets_opts.targets = {}
      create_module(targets_opts)
    end
  end

  local function get_loading_phase(module_opts, host_types, err)
    -- Check if we were able to get host types
    if err or host_types == nil then
      vim.notify("Could not get EHostType::Type", "error")
      return
    end
    -- Check if provided by the user
    if module_opts.loading_phase then
      local valid_loading_phase = false
      for _, i_path in ipairs(host_types) do
        if i_path == module_opts.loading_phase then
          valid_loading_phase = true
          break
        end
      end
      if valid_loading_phase then
        handle_targets(module_opts)
      else
        vim.notify(module_opts.loading_phase .. " is not a valid Loading Phase.", "error")
      end
    else
      unl_picker.pick({
        kind = "loading_phase_picker",
        title = "  Loading Phase",
        conf = require("UNL.config").get("UEP"),
        items = prepare_items(host_types),
        logger_name = "UEP",
        preview_enabled = false,
        on_submit = function(selected)
          if selected then
            module_opts.loading_phase = selected
            handle_targets(module_opts)
          end
        end,
      })
    end
  end

  -- Get host type if not provided by the user
  local function prepare_loading_phase(module_opts)
    unl_api.db.get_enum_values("ELoadingPhase::Type", function(host_types, err)
      get_loading_phase(module_opts, host_types, err)
    end)
  end

  -- Get the host type
  local function get_host_type(module_opts, host_types, err)
    -- Check if we were able to get host types
    if err or host_types == nil then
      vim.notify("Could not get EHostType::Type", "error")
      return
    end
    -- Check if provided by the user
    if module_opts.module_type then
      -- Check if provided host type is valid
      local valid_module_type = false
      for _, i_path in ipairs(host_types) do
        if i_path == module_opts.module_type then
          valid_module_type = true
          break
        end
      end
      if valid_module_type then
        prepare_loading_phase(module_opts)
      else
        vim.notify(module_opts.module_type .. " is not a valid module type.", "error")
      end
    else
      -- Open picker for Host Types
      unl_picker.pick({
        kind = "module_type_picker",
        title = "  Module Type",
        conf = require("UNL.config").get("UEP"),
        items = prepare_items(host_types),
        logger_name = "UEP",
        preview_enabled = false,
        on_submit = function(selected)
          if selected then
            module_opts.module_type = selected
            prepare_loading_phase(module_opts)
          end
        end,
      })
    end
  end

  -- Get host type if not provided by the user
  local function prepare_host_type(module_opts)
    -- Handle module path
    local sanitized_input = module_opts.module_path:gsub("\\", "/"):gsub("(.-)[/\\]*$", "%1")
    module_opts.module_name = vim.fs.basename(sanitized_input)
    module_opts.subdir_path = vim.fs.dirname(sanitized_input)

    -- Check if provided directory is valid
    if
      vim.fn.isdirectory(module_opts.subdir_path) ~= 0
      and vim.fn.filereadable(sanitized_input) == 0
      and vim.fn.isdirectory(sanitized_input) == 0
    then
      -- Get all available host type
      unl_api.db.get_enum_values("EHostType::Type", function(host_types, err)
        get_host_type(module_opts, host_types, err)
      end)
    else
      vim.notify("Folder " .. module_opts.subdir_path .. " does not exist.", "error")
    end
  end

  -- Get module path
  if opts.module_path then
    prepare_host_type(opts)
  else
    local function ask_for_module_name_and_path()
      vim.ui.input({
        prompt = "Enter Module Name (e.g., path/to/MyModule):",
        completion = "dir",
      }, function(user_input)
        if not user_input or user_input == "" then
          return log.get().info("Module creation canceled.")
        end
        prepare_host_type({ module_path = user_input })
      end)
    end
    ask_for_module_name_and_path()
  end
end

return M
