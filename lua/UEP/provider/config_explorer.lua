-- lua/UEP/provider/config_explorer.lua (RPC Optimized)
local unl_api = require("UNL.api")
local uep_log = require("UEP.logger")
local fs = require("vim.fs")
local unl_parser_ini = require("UNL.parser.ini")

local M = {}

-- (Helper functions apply_config_op, format_value_for_display, parse_device_profiles_ini, etc remain same)
local function apply_config_op(current, op, new_value)
    local is_array = type(current) == "table"
    if op == "!" then return nil
    elseif op == "-" then
        if is_array then
            local filtered = {}
            for _, v in ipairs(current) do if v ~= new_value then table.insert(filtered, v) end end
            return #filtered > 0 and filtered or nil
        elseif current == new_value then return nil end
        return current
    elseif op == "+" then
        if not current then return { new_value } end
        if not is_array then current = { current } end
        table.insert(current, new_value)
        return current
    else return new_value end
end

local function format_value_for_display(val)
    if type(val) == "table" then return string.format("[Array x%d] %s", #val, val[#val]) end
    if not val then return "nil" end
    if type(val) ~= "string" then val = tostring(val) end
    if #val > 50 then return val:sub(1, 47) .. "..." end
    return val
end

local function parse_device_profiles_ini(filepath, profiles_map)
    local parsed = unl_parser_ini.parse(filepath)
    if not parsed or not parsed.sections then return end
    local filename_short = vim.fn.fnamemodify(filepath, ":t")

    for section_name, items in pairs(parsed.sections) do
        local profile_name = section_name:match("^(.*)%s+DeviceProfile$")
        if profile_name then
            if not profiles_map[profile_name] then
                local parent_plat = profile_name:match("^([^_]+)") or profile_name
                profiles_map[profile_name] = { name = profile_name, parent_platform = parent_plat, cvars = {} }
            end
            for _, item in ipairs(items) do
                if item.key == "CVars" or item.key == "+CVars" then
                    local cvar_key, cvar_val = item.value:match("^([^=]+)=(.*)$")
                    if cvar_key then
                        table.insert(profiles_map[profile_name].cvars, {
                            key = vim.trim(cvar_key), value = vim.trim(cvar_val or ""), op = "", 
                            line = item.line, raw_file = filename_short, full_path = filepath
                        })
                    end
                end
            end
        end
    end
end

local function get_available_device_profiles(maps)
    local profiles = {} 
    if maps.engine_root then
        parse_device_profiles_ini(fs.joinpath(maps.engine_root, "Engine/Config/BaseDeviceProfiles.ini"), profiles)
    end
    if maps.project_root then
        parse_device_profiles_ini(fs.joinpath(maps.project_root, "Config/DefaultDeviceProfiles.ini"), profiles)
    end
    return profiles
end

local function get_available_platforms(engine_root)
    local config_root = fs.joinpath(engine_root, "Engine", "Config")
    local platforms = {}
    local seen = {}
    local handle = vim.loop.fs_scandir(config_root)
    if handle then
        while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            if (type == "directory" or type == "link") and not name:match("^%.") then
                local check_ini = fs.joinpath(config_root, name, name .. "Engine.ini")
                if vim.fn.filereadable(check_ini) == 1 then table.insert(platforms, name); seen[name] = true end
            end
        end
    end
    local major = { "Windows", "Mac", "Linux", "Android", "IOS", "TVOS", "Apple", "Unix" }
    for _, p in ipairs(major) do
        if not seen[p] then
            local p_dir = fs.joinpath(config_root, p)
            if vim.fn.isdirectory(p_dir) == 1 then table.insert(platforms, p); seen[p] = true end
        end
    end
    table.sort(platforms)
    return platforms
end

local function get_config_stack(maps, target)
    local stack = {}
    local p_root = maps.project_root
    local e_root = maps.engine_root
    local platform = target.platform 
    if e_root then 
        table.insert(stack, { type="file", path=fs.joinpath(e_root, "Engine/Config/Base.ini") })
        table.insert(stack, { type="file", path=fs.joinpath(e_root, "Engine/Config/BaseEngine.ini") })
    end
    if e_root and platform then
        if platform == "Mac" or platform == "IOS" or platform == "TVOS" then table.insert(stack, { type="file", path=fs.joinpath(e_root, "Engine/Config/Apple/AppleEngine.ini") }) end
        if platform == "Linux" then table.insert(stack, { type="file", path=fs.joinpath(e_root, "Engine/Config/Unix/UnixEngine.ini") }) end
    end
    if e_root and platform and platform ~= "Default" then table.insert(stack, { type="file", path=fs.joinpath(e_root, "Engine/Config", platform, platform .. "Engine.ini") }) end
    if p_root then table.insert(stack, { type="file", path=fs.joinpath(p_root, "Config/DefaultEngine.ini") }) end
    if p_root and platform and platform ~= "Default" then table.insert(stack, { type="file", path=fs.joinpath(p_root, "Config", platform, platform .. "Engine.ini") }) end
    if target.is_profile and target.cvars then
        local virtual_data = { SystemSettings = {} }
        for _, cvar in ipairs(target.cvars) do
            table.insert(virtual_data.SystemSettings, { key = cvar.key, value = cvar.value, op = cvar.op, line = cvar.line, raw_file = "Profile: " .. cvar.raw_file, full_path = cvar.full_path })
        end
        table.insert(stack, { type="virtual", data=virtual_data, name=target.name })
    end
    return stack
end

local function resolve_config_settings(stack)
    local resolved = {} 
    for _, source in ipairs(stack) do
        local sections_data = nil
        local source_name = ""
        local full_path = ""
        if source.type == "file" then
            local parsed = unl_parser_ini.parse(source.path)
            if parsed then sections_data = parsed.sections end
            full_path = source.path
            source_name = vim.fn.fnamemodify(source.path, ":t")
            local parent = vim.fn.fnamemodify(source.path, ":h:t")
            if parent ~= "Config" then source_name = parent .. "/" .. source_name end
        elseif source.type == "virtual" then
            sections_data = source.data
            source_name = source.name 
            full_path = "DeviceProfile"
        end
        if sections_data then
            for section, items in pairs(sections_data) do
                if not resolved[section] then resolved[section] = {} end
                for _, item in ipairs(items) do
                    local key = item.key
                    if not resolved[section][key] then resolved[section][key] = { value = nil, history = {} } end
                    local entry = resolved[section][key]
                    entry.value = apply_config_op(entry.value, item.op, item.value)
                    table.insert(entry.history, {
                        file = source.type == "virtual" and item.raw_file or source_name,
                        full_path = source.type == "virtual" and item.full_path or full_path,
                        value = format_value_for_display(entry.value),
                        op = item.op,
                        line = item.line
                    })
                end
            end
        end
    end
    return resolved
end

local function build_config_tree_nodes(maps)
    local root_nodes = {}
    local targets_map = {}
    local targets_order = {}
    local function add_or_merge_target(t)
        if not targets_map[t.name] then targets_map[t.name] = t; table.insert(targets_order, t.name)
        else
            local existing = targets_map[t.name]
            if t.cvars and #t.cvars > 0 then existing.cvars = t.cvars; existing.is_profile = true end
            if not existing.platform and t.platform then existing.platform = t.platform end
        end
    end
    add_or_merge_target({ name = "Default (Editor)", platform = "Default" })
    if maps.engine_root then
        local platforms = get_available_platforms(maps.engine_root)
        for _, p in ipairs(platforms) do add_or_merge_target({ name = p, platform = p, is_profile = false }) end
        local profiles = get_available_device_profiles(maps)
        local profile_names = vim.tbl_keys(profiles)
        table.sort(profile_names)
        for _, pname in ipairs(profile_names) do
            local pdata = profiles[pname]
            local parent_valid = (pdata.parent_platform == "Windows")
            if not parent_valid then for _, pp in ipairs(platforms) do if pp == pdata.parent_platform then parent_valid = true; break end end end
            if parent_valid then add_or_merge_target({ name = pname, platform = pdata.parent_platform, is_profile = true, cvars = pdata.cvars }) end
        end
    end
    for _, tname in ipairs(targets_order) do
        local target = targets_map[tname]
        local stack = get_config_stack(maps, target)
        local resolved_data = resolve_config_settings(stack)
        local platform_children = {}
        local sections = vim.tbl_keys(resolved_data)
        table.sort(sections)
        for _, section in ipairs(sections) do
            local keys_data = resolved_data[section]
            local section_children = {}
            local keys = vim.tbl_keys(keys_data)
            table.sort(keys)
            for _, key in ipairs(keys) do
                local info = keys_data[key]
                local display_value = format_value_for_display(info.value)
                local history_nodes = {}
                for i, h in ipairs(info.history) do
                    local op_display = h.op == "" and "=" or h.op
                    table.insert(history_nodes, {
                        id = string.format("hist_%s_%s_%s_%d_%d", target.name, section, key, h.line, i),
                        name = string.format("%s %s [%s]", op_display, h.value, h.file),
                        type = "history", loaded = true, extra = { filepath = h.full_path, line = h.line, op = h.op }
                    })
                end
                table.insert(section_children, { id = string.format("%s_%s_%s", target.name, section, key), name = key, type = "parameter", loaded = true, children = #history_nodes > 0 and history_nodes or nil, extra = { final_value = display_value } })
            end
            if #section_children > 0 then table.insert(platform_children, { id = string.format("%s_%s", target.name, section), name = section, type = "section", loaded = true, children = section_children }) end
        end
        if #platform_children > 0 then table.insert(root_nodes, { id = "target_" .. target.name, name = target.name, type = target.is_profile and "profile" or "platform", loaded = true, children = platform_children }) end
    end
    return root_nodes
end

function M.request(opts, on_complete)
  unl_api.project.get_maps(vim.loop.cwd(), function(ok, maps)
    if not ok then
        if on_complete then on_complete(false, maps) end
        return
    end
    local top_nodes = build_config_tree_nodes(maps)
    local result = {{
        id = "config_logical_root",
        name = "Config Explorer",
        type = "root",
        loaded = true,
        children = top_nodes,
        extra = { uep_type = "config_root" }
    }}
    if on_complete then on_complete(true, result) end
  end)
end

return M