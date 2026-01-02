-- lua/UEP/cmd/module_tree.lua

local uep_log = require("UEP.logger")
local uep_config = require("UEP.config")
local uep_utils = require("UEP.cmd.core.utils")
local unl_picker = require("UNL.backend.picker")
local ui_control = require("UEP.cmd.core.ui_control")
local unl_finder = require("UNL.finder")

local M = {}

local function open_tree(module_name)
    local log = uep_log.get()
    log.info("Opening tree for module: %s", module_name)

    local project_root = unl_finder.project.find_project_root(vim.loop.cwd())
    if not project_root then return log.error("Not in an Unreal Engine project.") end

    local proj_info = unl_finder.project.find_project(project_root)
    local engine_root = proj_info and unl_finder.engine.find_engine_root(proj_info.uproject,
        { engine_override_path = uep_config.get().engine_path })

    local payload = {
        project_root = project_root,
        engine_root = engine_root,
        all_deps = false, -- Single module
        target_module = module_name,
        scope = "Module", -- Special scope for module tree
        deps_flag = "--no-deps",
    }

    ui_control.handle_tree_request(payload)
end

function M.execute(opts)
    opts = opts or {}
    local log = uep_log.get()

    if opts.module_name then
        open_tree(opts.module_name)
    else
        log.info("No module name specified, showing picker...")
        uep_utils.get_project_maps(vim.loop.cwd(), function(map_ok, maps)
            if not map_ok then
                log.error("Failed to get module list for picker: %s", tostring(maps))
                return vim.notify("Error getting module list.", vim.log.levels.ERROR)
            end

            local all_modules_picker = {}
            for mod_name, mod_meta in pairs(maps.all_modules_map or {}) do
                local owner_display = "Unknown"
                if maps.all_components_map and maps.all_components_map[mod_meta.owner_name] then
                    owner_display = maps.all_components_map[mod_meta.owner_name].type
                end
                table.insert(all_modules_picker, {
                    label = string.format("%s (%s - %s)", mod_name, owner_display, mod_meta.type or "N/A"),
                    value = mod_name
                })
            end

            if #all_modules_picker == 0 then return log.error("No modules found for picker.") end
            table.sort(all_modules_picker, function(a, b) return a.label < b.label end)

            unl_picker.pick({
                kind = "uep_select_module",
                title = "Select a Module for Tree",
                items = all_modules_picker,
                conf = uep_config.get(),
                preview_enabled = false,
                devicons_enabled = false,
                on_submit = function(selected_module_name)
                    if selected_module_name then
                        open_tree(selected_module_name)
                    end
                end,
                logger_name = uep_log.name,
            })
        end)
    end
end

return M
