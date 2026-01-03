-- plugin/UEP.lua (括弧修正版)

local command_builder = require("UNL.command.builder")
local uep_api = require("UEP.api")

local command_spec = { -- line 10: 開始の '{'
  plugin_name = "UEP",
  cmd_name = "UEP",
  version = "nvim-0.11.3", -- 必要に応じて更新
  desc = "UEP for Unreal Engine main command",
  dependencies = {
    { name = "fd", check = function() return vim.fn.executable("fd") == 1 end, msg = "Please install fd." },
    { name = "rg", check = function() return vim.fn.executable("rg") == 1 end, msg = "Please install ripgrep (rg) for grep commands." },
  },

  subcommands = {
    refresh = {
      handler = uep_api.refresh,
      bang = true,
      desc = ":UEP refresh [Scope] [--force]", -- Scope は Game|Engine|Full
      args = {
        { name = "scope", required = false },
        { name = "force_flag", required = false }, -- ★ force -> force_flag に変更 (UNL builder 仕様)
      },
    },
    reloadconfig = {
      handler = uep_api.reload_config,
      desc = "Reload the configuration files.",
      args = {},
    },
    cd = {
      handler = uep_api.cd,
      desc = "Select a known project and cd to it.",
      args = {},
    },
    delete = {
      handler = uep_api.delete,
      desc = "Select a project to remove it from the known projects list.",
      args = {},
    },
    files = {
      handler = uep_api.files,
      bang = true,
      desc = ":UEP files [Scope] [Mode] [DepsFlag]",
      args = {
        { name = "scope", required = false },
        { name = "mode", required = false },
        { name = "deps_flag", required = false },
      },
    },
    module_files = {
      handler = uep_api.module_files,
      bang = true,
      desc = "Find all files for a specific module.",
      args = {
        { name = "module_name", required = false },
        { name = "dummy_arg", required = false }, -- 必要なら削除
      },
    },
    module_tree = {
      handler = uep_api.module_tree,
      desc = "Open project filer for a specific module.",
      args = {
        { name = "module_name", required = false },
      },
    },
    tree = {
      handler = uep_api.tree,
      desc = "Open project filer. Scope: Game|Engine|Runtime(default)|Developer|Editor|Full.",
      args = {
        { name = "scope", required = false },
        { name = "deps_flag", required = false },
      },
    },
    close_tree = {
      handler = uep_api.close_tree,
      desc = "Close neo-tree and clear the expanded state.",
      args = {},
    },
    grep = {
      handler = uep_api.grep,
      bang = true,
      desc = "Live grep files. Scope: Game|Engine|Runtime(default)|Developer|Editor|Full|Programs|Config.",
      args = {
        { name = "scope", required = false },
        { name = "mode", required = false },
        { name = "deps_flag", required = false },
      },
    },
    module_grep = {
      handler = uep_api.module_grep,
      bang = true,
      desc = "Live grep within a specific module.",
      args = {
        { name = "module_name", required = false },
      },
    },
    find_derived = {
      handler = uep_api.find_derived,
      bang = true,
      desc = "Find all derived classes of a specified base class.",
      args = {
        { name = "class_name", required = false },
      },
    },
    find_parents = {
      handler = uep_api.find_parents,
      bang = true,
      desc = "Find the inheritance chain of a specified class.",
      args = {
        { name = "class_name", required = false },
      },
    },
    open_file = {
      handler = uep_api.open_file,
      desc = "Open an include file by searching the project cache.",
      args = {
        { name = "path", required = false },
      },
    },
    cleanup = {
      handler = uep_api.cleanup,
      desc = "Delete all structural and file caches for the current project.",
      args = {},
    },
    add_include = {
      handler = uep_api.add_include,
      bang = true,
      desc = "Finds and inserts the #include directive for the specified class.",
      args = {
        { name = "class_name", required = false },
      },
    },
    goto_definition = {
      handler = uep_api.goto_definition,
      bang = true,
      desc = "Jump to true definition (skips forward declarations). Use `!` for class picker.",
      args = {
        { name = "class_name", required = false },
      },
    },
    classes = {
      handler = uep_api.classes,
      bang = true,
      desc = "Find and jump to a class definition. Scope/Deps flags available.",
      args = {
        { name = "scope", required = false },
        { name = "deps_flag", required = false },
      },
    },
    structs = {
      handler = uep_api.structs,
      bang = true,
      desc = "Find and jump to a struct definition. Scope/Deps flags available.",
      args = {
        { name = "scope", required = false },
        { name = "deps_flag", required = false },
      },
    },

    enums = {
      handler = uep_api.enums,
      bang = true,
      desc = "Find and jump to an enum definition. Scope/Deps flags available.",
      args = {
        { name = "scope", required = false },
        { name = "deps_flag", required = false },
      },
    },
    ["system_open"] = {
      handler = uep_api.system_open,
      bang = true,
      desc = "Open the file location in system explorer. Use '!' to pick from project files.",
      args = { { name = "path", required = false } },
    },
    ["implement_virtual"] = {
      handler = uep_api.implement_virtual, 
      desc = "Override a virtual function from the parent class.",
      args = {
        { name = "class_name", required = false },
      },
    },
    ["goto_super_def"] = {
      handler = uep_api.goto_super_def,
      desc = "Jump to the parent class definition of the current function.",
      args = {},
    },
    ["goto_super_impl"] = {
      handler = uep_api.goto_super_impl,
      desc = "Jump to parent implementation (Source) of the current function.",
      args = {},
    },
    config_tree = { -- ★新規追加
      handler = uep_api.config_tree,
      desc = "Open config override explorer. Scope: Game|Engine|Full.",
      args = {
        { name = "scope", required = false },
      },
    },

    web_doc = {
      handler = uep_api.web_doc,
      bang = true,
      desc = "Search Unreal Engine Web Docs. Use '!' to open browser directly.",
      args = {
        { name = "query", required = false },
      },
    },
    build_cs = {
      handler = uep_api.build_cs,
      bang = true,
      desc = "Open Build.cs of the current module. Use '!' to list all modules.",
      args = {},
    },
    -- ★ 変更: target_cs
    target_cs = {
      handler = uep_api.target_cs,
      bang = true,
      desc = "Open Target.cs. Use '!' to force list selection.",
      args = {},
    },
    shader_files = {
      handler = uep_api.shader_files, -- API名も変更済みのものを指定
      bang = true,
      desc = "List and select shader files (.usf, .ush).",
      args = {
        { name = "scope", required = false },
        { name = "deps_flag", required = false },
      },
    },
    ["class_symbol"] = {
      handler = uep_api.class_symbol,
      desc = "Jump to a symbol in a class (Pick Class -> Pick Symbol).",
      args = {
        { name = "scope", required = false },
        { name = "deps_flag", required = false },
      },
    },
    ["new_project"] = {
      handler = uep_api.new_project,
      desc = "Create a new Unreal Engine project from a template.",
      args = {},
    },
   ["gen_compile_commands_fast"] = {
      handler = uep_api.gen_compile_commands_fast,
      bang = true,
      desc = "Generate compile_commands.json from existing build artifacts (Fast/Shadow).",
      args = {
        { name = "platform", required = false }, -- 必要なら引数拡張
      },
    },
    ["clean_intermediate"] = {
      handler = uep_api.clean_intermediate,
      bang = true, -- 確認なしで実行したい場合はbangを使うロジックを追加可能ですが、今回は安全のため必ず確認を入れています
      desc = "Delete Intermediate folders. Scope: Project(default)|Engine|All.",
      args = {
        { name = "scope", required = false }, -- "project", "engine", "all"
      },
    },
  }, -- <<< subcommands テーブルを閉じる '}'

} -- <<< command_spec テーブル全体を閉じる '}' (★ これが抜けていた可能性)

-- コマンド登録
command_builder.create(command_spec)
