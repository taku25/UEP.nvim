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
      desc = ":UEP files [Scope] [DepsFlag]",
      args = {
        { name = "scope", required = false },
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
    tree = {
      handler = uep_api.tree,
      desc = "Open project filer. Scope: Game|Engine|Runtime(default)|Developer|Editor|Full.",
      args = {
        { name = "scope", required = false },
        { name = "deps_flag", required = false },
      },
    },
    module_tree = {
      handler = uep_api.module_tree,
      desc = "Open filer focused on a module and its dependencies.",
      args = {
        { name = "module_name", required = false },
        { name = "deps_flag", required = false },
      },
    },
    grep = {
      handler = uep_api.grep,
      bang = true,
      desc = "Live grep files. Scope: Game|Engine|Runtime(default)|Developer|Editor|Full.",
      args = {
        { name = "scope", required = false },
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
    program_grep = {
      handler = uep_api.program_grep,
      desc = "Live grep within all Program modules.",
      args = {},
    },
    program_files = {
      handler = uep_api.program_files,
      desc = "Find all files in Program modules.",
      args = {},
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
    purge = {
      handler = uep_api.purge,
      desc = "Purge the file cache for a specified component (Game/Engine/Plugin).",
      args = {
        { name = "component_name", required = false }, -- ★ 注意: これはコンポーネントキャッシュ用。モジュールキャッシュ移行後は削除 or 変更が必要
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
  }, -- <<< subcommands テーブルを閉じる '}'

} -- <<< command_spec テーブル全体を閉じる '}' (★ これが抜けていた可能性)

-- コマンド登録
command_builder.create(command_spec)
