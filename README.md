# UEP.nvim

# Unreal Engine Project Explorer 💓 Neovim

`UEP.nvim` is a Neovim plugin designed to understand, navigate, and manage the structure of your Unreal Engine projects. It asynchronously parses and caches all module and file information for the entire project, providing an incredibly fast and intelligent file navigation experience.

It forms a core part of the **Unreal Neovim Plugin Stack** and relies on [UNL.nvim](https://www.google.com/search?q=https://github.com/taku25/UNL.nvim) as its library.

Using [UBT](https://github.com/taku25/UBT.nvim) allows you to run tasks like Build and GenerateClangDataBase asynchronously from within Neovim.
Using [UCM](https://www.google.com/search?q=https://github.com/taku25/UCM.nvim) allows you to add and delete classes from within Neovim.

[English](README.md) | [日本語 (Japanese)](README_ja.md)

-----

## ✨ Features

  * **Fast, Asynchronous Caching**:
      * Scans the entire project (both Game and linked Engine modules) in the background without blocking the UI.
      * Intelligently separates Game and Engine caches, allowing multiple projects to share a single Engine cache for maximum efficiency.
      * The `generation` hash system ensures that the file list is always in sync with the module structure.
  * **Powerful File Finding**:
      * Provides a flexible `:UEP files` command to instantly find files.
      * Filter files by scope (**Game**, **Engine**).
      * Include module dependencies (**--no-deps** `dependencies` or **--all-deps** `dependencies`) in your search.
  * **UI Integration**:
      * Leverages `UNL.nvim`'s UI abstraction layer to automatically use UI frontends like [Telescope](https://github.com/nvim-telescope/telescope.nvim) or [fzf-lua](https://github.com/ibhagwan/fzf-lua).
      * Falls back to the native Neovim UI if no UI plugin is installed.
  * **File Tree Display for Single Modules**:
      * The `:UEP tree` command can display the root of a module in a filer plugin like [Neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim).

-----

## 🔧 Requirements

  * Neovim v0.11.3 or higher
  * [**UNL.nvim**](https://www.google.com/search?q=https://github.com/taku25/UNL.nvim) (**Required**)
  * [fd](https://github.com/sharkdp/fd) (**Required** for project scanning)
  * **Optional (Strongly recommended for an enhanced UI experience):**
      * [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
      * [fzf-lua](https://github.com/ibhagwan/fzf-lua)
      * [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) (Recommended for the `:UEP tree` command)

-----

## 🚀 Installation

Install using your favorite plugin manager.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  'taku25/UEP.nvim',
  -- UNL.nvim is a mandatory dependency
  dependencies = { 'taku25/UNL.nvim' },
  -- All configuration is inherited from UNL.nvim, but can be overridden here
  opts = {
    -- Your UEP-specific configurations can go here
  },
}
```

-----

## ⚙️ Configuration

This plugin is configured via the setup function of its library, `UNL.nvim`. However, you can pass `opts` directly to `UEP.nvim` to set the configuration for the `UEP` namespace.

The following shows the default values relevant to `UEP.nvim`.

```lua
-- In your lazy.nvim spec for UEP.nvim or UNL.nvim:
opts = {
  -- UEP specific settings
  uep = {
    -- This section is for future UEP-specific settings
  },

  -- File extensions to be scanned by the ':UEP refresh' command
  files_extensions = {
    "cpp", "h", "hpp", "inl", "ini", "cs",
  },

  -- Settings for the UI backend (inherited from UNL.nvim)
  ui = {
    picker = {
      mode = "auto", -- "auto", "telescope", "fzf_lua", "native"
      prefer = { "telescope", "fzf_lua", "native" },
    },
    progress = {
      enable = true,
      mode = "auto", -- "auto", "fidget", "window", "notify"
      prefer = { "fidget", "window", "notify" },
    },
  },
}
```

-----

## ⚡ Usage

All commands begin with `:UEP`.

```viml
" Re-scans the project and updates the cache. This is the most important command.
:UEP refresh [Game|Engine]

" Opens a UI to find files based on various criteria.
:UEP files[!] [Game|Engine|All] [--no-deps|--all-deps]

" Finds files belonging to a specific module.
:UEP module_files[!] [ModuleName]

" Opens a UI to select a known project and changes the current directory to it.
:UEP cd

" Removes a project from the known projects list (does not delete files).
:UEP delete

" Opens the module root in a filer.
:UEP tree
```

### Command Details

  * **`:UEP refresh`**:
      * `Game` (default): Scans only the modules of the current game project. If the linked engine hasn't been cached, it will be scanned first automatically.
      * `Engine`: Scans only the modules of the linked engine.
  * **`:UEP files[!]`**:
      * Without `!`: Selects files from the existing cache data.
      * With `!`: Deletes the cache and creates a new one before selecting files.
      * `[Game|Engine]` (default `Game`): The scope of modules to search within.
      * `[--no-deps|--all-deps]` (default `--no-deps`):
          * `--no-deps`: Searches only within the modules of the specified scope.
          * `--all-deps`: Includes all modules that are dependencies (uses `deep_dependencies`).
  * **`:UEP module_files[!]`**:
      * Without `!`: Searches for files in the specified module using the existing cache.
      * With `!`: Forces a lightweight refresh of only the specified module's files before searching.

-----

## 🤖 API & Automation Examples

You can use the `UEP.api` module to integrate with other parts of your Neovim config.

### Quick File Finder Keymap

Create a keymap to quickly open the file finder for the current project.

```lua
-- in your init.lua or a dedicated keymaps file
vim.keymap.set('n', '<leader>pf', function()
  -- The API is simple and clean
  require('UEP.api').files({})
end, { desc = "[P]roject [F]iles" })
```

### Neo-tree Integration

Add a keymap in Neo-tree to open the UEP filer focused on the selected directory's project.

```lua
-- Example Neo-tree config
opts = {
  filesystem = {
    window = {
      mappings = {
        ["<leader>pf"] = function(state)
          -- Get the directory of the currently selected node
          local node = state.tree:get_node()
          local path = node:get_id()
          if node.type ~= "directory" then
            path = require("vim.fs").dirname(path)
          end

          -- Ensure CWD is inside the project before calling the API
          vim.api.nvim_set_current_dir(path)
          require("UEP.api").tree({})
        end,
      },
    },
  },
}
```

-----

## 📜 License

MIT License

Copyright (c) 2025 taku25

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.