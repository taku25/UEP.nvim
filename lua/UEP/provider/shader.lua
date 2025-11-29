-- lua/UEP/provider/shader.lua

local uep_config = require("UEP.config")
local fs = require("vim.fs")
local uep_log = require("UEP.logger")

local M = {}

-- プロジェクトマップから仮想パスのマッピングを作成
local function build_shader_map(maps)
    local mapping = {}
    
    -- 1. Engine Shaders
    if maps.engine_root then
        local engine_shaders = fs.joinpath(maps.engine_root, "Engine", "Shaders")
        if vim.fn.isdirectory(engine_shaders) == 1 then
            mapping["/Engine/"] = engine_shaders
        end
    end

    -- 2. Plugin / Module Shaders
    if maps.all_modules_map then
        for mod_name, mod_meta in pairs(maps.all_modules_map) do
            if mod_meta.module_root then
                local shader_dir = fs.joinpath(mod_meta.module_root, "Shaders")
                if vim.fn.isdirectory(shader_dir) == 1 then
                    -- "/Module/" -> ".../Module/Shaders"
                    local virtual_key = "/" .. mod_name .. "/"
                    mapping[virtual_key] = shader_dir
                end
            end
        end
    end

    -- 3. Manual Config Mappings
    local conf = uep_config.get()
    if conf.shader and conf.shader.extra_mappings then
        for virtual, physical in pairs(conf.shader.extra_mappings) do
            local abs_physical = fs.normalize(physical)
            if not fs.is_absolute(physical) and maps.project_root then
                abs_physical = fs.joinpath(maps.project_root, physical)
            end
            
            local key = virtual
            if key:sub(1, 1) ~= "/" then key = "/" .. key end
            if key:sub(-1) ~= "/" then key = key .. "/" end
            
            mapping[key] = abs_physical
        end
    end

    return mapping
end

---
-- 仮想パスを物理パスに解決する
-- @param virtual_path string (例: "/Engine/Private/Common.ush")
-- @param maps table get_project_mapsの結果
-- @return string|nil 物理パス (存在する場合のみ返す)
function M.resolve(virtual_path, maps)
    if not virtual_path or virtual_path == "" then return nil end
    
    -- マッピング構築
    local mapping = build_shader_map(maps)
    
    -- 最長一致でプレフィックスを探す
    local best_prefix = ""
    local best_physical = ""
    
    -- パス区切り文字の正規化 (/ に統一)
    local v_path_norm = virtual_path:gsub("\\", "/")
    
    for prefix, physical in pairs(mapping) do
        -- 大文字小文字を区別せず前方一致
        if v_path_norm:lower():find(prefix:lower(), 1, true) == 1 then
            if #prefix > #best_prefix then
                best_prefix = prefix
                best_physical = physical
            end
        end
    end
    
    if best_prefix ~= "" then
        -- プレフィックス以降の部分を取得して結合
        -- 例: /Engine/Private/X.ush - /Engine/ = Private/X.ush
        --     Physical/Engine/Shaders + Private/X.ush
        local relative_part = v_path_norm:sub(#best_prefix + 1)
        
        -- ディレクトリ結合 (vim.fs.joinpath は可変長引数)
        -- best_physical は末尾に / がないかもしれないので fs.joinpath に任せる
        local resolved = fs.joinpath(best_physical, relative_part)
        
        -- ファイル存在確認
        if vim.fn.filereadable(resolved) == 1 then
            return resolved
        end
        
        -- 失敗した場合、Shadersフォルダ直下ではなく、サブフォルダ構造が違う可能性も考慮？
        -- いったんはこれで返す
    end
    
    return nil
end

return M
