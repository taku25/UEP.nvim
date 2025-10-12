-- plugin/UEP.lua (最終修正版)

local command_builder = require("UNL.command.builder")
local uep_api = require("UEP.api") -- apiのrequireは必要

-- ★★★ 変更点: 初期化コードを完全に削除 ★★★
-- 以下の2行を削除します:
-- local unl_log = require("UNL.logging").get() or require("UNL.logging").setup({})

local command_spec = {
  plugin_name = "UEP",
  cmd_name = "UEP",
  version = "nvim-0.11.3",
  -- ★★★ 変更点: logger = unl_log の行を削除 ★★★
  desc = "UEP for Unreal Engine main command",
  dependencies = {
    { name = "fd", check = function() return vim.fn.executable("fd") == 1 end, msg = "Please install fd." },
  },

  subcommands = {
    refresh = {
      handler = uep_api.refresh, -- uep_api を使うように修正
      bang = true,
      desc = ":UEP refresh [Game|Engine]",
      args = {
        { name = "type", required = false },
        { name = "force", required = false }, -- 例: --force
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
      desc = ":UEP files [Category] [--no-deps]",
      args = {
        { name = "category", required = false },
        { name = "deps_flag", required = false }, -- 例: --no-deps or --all-deps
      },
    },
    module_files = {
      handler = uep_api.module_files,
      bang = true,
      desc = "Find all files for a specific module.",
      args = {
        { name = "module_name", required = false },
      { name = "dummy_arg", required = false },
      },
    },
    tree = {
      handler = uep_api.tree,
      desc = "Open a project-aware filer (requires neo-tree or nvim-tree)",
      args = {
        { name = "deps_flag", required = false }, -- 例: --no-deps or --all-deps
      },
    },
    module_tree = {
      handler = uep_api.module_tree,
      desc = "Open a project-aware filer (requires neo-tree or nvim-tree)",
      args = {
        { name = "module_name", required = false },
        { name = "deps_flag", required = false }, -- 例: --no-deps or --all-deps
      },
    },
    grep = {
      handler = uep_api.grep,
      bang = true,
      desc = ":UEP grep [game|engine]",
      args = {
        { name = "category", required = false },
      },
    },
    module_grep = {
      handler = uep_api.module_grep,
      bang = true,
      desc = ":UEP grep_module {module_name}",
      args = {
        { name = "module_name", required = false },
      },
    },
    program_files = {
      handler = uep_api.program_files,
      desc = "Find all files in Programs directories.",
      args = {},
    },
    program_grep = {
      handler = uep_api.program_grep,
      desc = "Live grep within all Programs directories.",
      args = {},
    },
    find_derived = {
      handler = uep_api.find_derived,
      desc = "Find all derived classes of a specified base class.",
      args = {
        { name = "class_name", required = false },
      },
    },
    find_parents = {
      handler = uep_api.find_parents,
      desc = "Find the inheritance chain of a specified class.",
      args = {
        { name = "class_name", required = false },
      },
    },
  },
}

-- command_spec テーブルをビルダーに渡してコマンドを作成
command_builder.create(command_spec)
