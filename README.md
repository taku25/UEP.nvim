# UEP.nvim

# Unreal Engine Project Explorer 💓 Neovim

<table>
  <tr>
   <td><div align=center><img width="100%" alt="UEP Refresh Demo" src="https://raw.githubusercontent.com/taku25/UEP.nvim/images/assets/uep_refresh.gif" /></div></td>
   <td><div align=center><img width="100%" alt="UEP Tree Demo" src="https://raw.githubusercontent.com/taku25/UEP.nvim/images/assets/uep_tree.gif" /></div></td>
  </tr>
</table>

`UEP.nvim` is a Neovim plugin designed to understand, navigate, and manage the structure of Unreal Engine projects. It asynchronously parses and caches module and file information for the entire project, providing an exceptionally fast and intelligent file navigation experience.

This is a core plugin in the **Unreal Neovim Plugin suite** and depends on [UNL.nvim](https://github.com/taku25/UNL.nvim) as its library.

With [UBT](https://github.com/taku25/UBT.nvim), you can use features like Build and GenerateClangDataBase asynchronously from within Neovim.
With [UCM](https://github.com/taku25/UCM.nvim), you can add and delete classes from within Neovim.
With [ULG](https://github.com/taku25/ULG.nvim), you can access UE logs, trigger Live Coding, and use `stat fps` from within Neovim.
With [neo-tree-unl](https://github.com/taku25/neo-tree-unl.nvim), you can display an IDE-like project explorer.
With [tree-sitter-unreal-cpp](https://github.com/taku25/tree-sitter-unreal-cpp), tree-sitter-unreal-cpp

[English](README.md) | [日本語 (Japanese)](README_ja.md)

-----

## ✨ Features

  * **Fast Asynchronous Caching**:
      * Scans the entire project (game and linked engine modules) in the background without blocking the UI.
      * Intelligently separates game and engine caches, maximizing efficiency by allowing multiple projects to share a single engine cache.
      * Ensures the file list is always in sync with the module structure through a `generation` hash system.
  * **Powerful File Searching**:
      * Provides a flexible `:UEP files` command to find your most-used source and config files instantly.
      * Offers specialized commands for targeted searches within a single module (`:UEP module_files`) or across all `Programs` directories (`:UEP program_files`).
      * Allows filtering files by scope (**Game**, **Engine**).
      * Supports including module dependencies in the search (**--no-deps** or **--all-deps**).
  * **Intelligent Content Searching (Grep)**:
      * Performs high-speed content searches across the entire project and engine source code (requires ripgrep).
      * The `:UEP grep` command lets you specify the search scope (**Game** (default), **Engine**).
      * The `:UEP module_grep` command enables focused, noise-free searches within a specific module (`<module_name>`).
  * **UI Integration**:
      * Leverages `UNL.nvim`'s UI abstraction layer to automatically use UI frontends like [Telescope](https://github.com/nvim-telescope/telescope.nvim) and [fzf-lua](https://github.com/ibhagwan/fzf-lua).
      * Falls back to the native Neovim UI if no UI plugin is installed.
  * **IDE-like Logical Tree View**:
      * Provides a logical tree view similar to an IDE's solution explorer through integration with **[neo-tree-unl.nvim](https://github.com/taku25/neo-tree-unl.nvim)**.
      * The `:UEP tree` command gives you an overview of the entire project structure (Game, Plugins, Engine).
      * The `:UEP module_tree` command allows you to switch to a view focused on a single module.
      * Running `:UEP refresh` automatically updates the open tree to the latest state.



## 🔧 Requirements

  * Neovim v0.11.3 or later
  * [**UNL.nvim**](https://github.com/taku25/UNL.nvim) (**Required**)
  * [fd](https://github.com/sharkdp/fd) (**Required for project scanning**)
  * [rg](https://github.com/BurntSushi/ripgrep) (**Required for project Grep**)
  * **Optional (Strongly recommended for the full experience):**
      * **UI (Picker):**
          * [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
          * [fzf-lua](https://github.com/ibhagwan/fzf-lua)
      * **UI (Tree View):**
          * [**neo-tree.nvim**](https://github.com/nvim-neo-tree/neo-tree.nvim)
          * [**neo-tree-unl.nvim**](https://github.com/taku25/neo-tree-unl.nvim) (**Required** for `:UEP tree` and `:UEP module_tree` commands)


## 🚀 Installation

Install with your favorite plugin manager.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  'taku25/UEP.nvim',
  -- UNL.nvim is a required dependency
  dependencies = {
     'taku25/UNL.nvim',
     'nvim-telescope/telescope.nvim', -- Optional
  },
  -- All settings are inherited from UNL.nvim, but can be overridden here
  opts = {
    -- UEP-specific settings can be placed here
  },
}
```

## ⚙️ Configuration

This plugin is configured through the setup function of its library, `UNL.nvim`. However, you can also pass `opts` directly to `UEP.nvim` to configure settings in the `UEP` namespace.

Below are the default values related to `UEP.nvim`.

```lua
-- Place inside the spec for UEP.nvim or UNL.nvim in lazy.nvim
opts = {
  -- UEP-specific settings
  uep = {
    -- Section for future UEP-specific settings
  },
  

  -- Directory names to search for files during tree construction
  include_directory = { "Source", "Plugins", "Config", },

  -- Folder names to exclude during tree construction
  excludes_directory  = { "Intermediate", "Binaries", "Saved" },

  -- File extensions to be scanned by the ':UEP refresh' command
  files_extensions = {
    "cpp", "h", "hpp", "inl", "ini", "cs",
  },

  -- UI backend settings (inherited from UNL.nvim)
  ui = {
    picker = {
      mode = "auto", -- "auto", "telescope", "fzf_lua", "native"
      prefer = { "telescope", "fzf_lua", "native" },
    },
    grep_picker = {
      mode = "auto",
      prefer = { "telescope", "fzf-lua" }
    },
    progress = {
      enable = true,
      mode = "auto", -- "auto", "fidget", "window", "notify"
      prefer = { "fidget", "window", "notify" },
    },
  },
}
```

## ⚡ Usage

All commands start with `:UEP`.

```viml
" Re-scan the project and update the cache. This is the most important command.
:UEP refresh [Game|Engine]

" Open a UI to search for commonly-used source and config files.
:UEP files[!] [Game|Engine] [--all-deps]

" Search for files belonging to a specific module.
:UEP module_files[!] [ModuleName]

" Search for files within Programs directories.
:UEP program_files

" LiveGrep across the project or engine source code.
:UEP grep [Game|Engine]

" LiveGrep files belonging to a specific module.
:UEP module_grep [ModuleName]

" Display the logical tree for the entire project (requires neo-tree-unl.nvim).
:UEP tree

" Display the logical tree for a specific module (requires neo-tree-unl.nvim).
:UEP module_tree [ModuleName]

" Display a list of known projects in a UI and change the current directory to the selected project.
:UEP cd

" Remove a project from the list of known projects (does not delete files).
:UEP delete
```

### Command Details
  * **`:UEP refresh`**:
      * `Game` (default): Scans only the modules of the current game project. If the linked engine is not cached, it will be scanned automatically first.
      * `Engine`: Scans only the modules of the linked engine.
  * **`:UEP cd`**:
      * Changes the current directory to the root of a project managed by UEP.
          * Projects are registered to management during `refresh`.
  * **`:UEP delete`**:
      * Deletes a project from UEP's management.
          * This only removes it from UEP's internal list; the actual UE project files are not deleted.
  * **`:UEP files[!]`**:
      * Without `!`: Selects files from the existing cache data.
      * With `!`: Deletes the cache and creates a new one before selecting files.
      * `[Game|Engine]` (default `Game`): The scope of modules to search.
      * `[--no-deps|--all-deps]` (default `--no-deps`):
          * `--no-deps`: Searches only within the modules of the specified scope.
          * `--all-deps`: Includes all dependent modules in the search (`deep_dependencies`).
  * **`:UEP module_files[!]`**:
      * Without `!`: Searches for files in the specified module using the existing cache.
      * With `!`: Performs a lightweight update of the file cache for only the specified module before searching.
  * **`:UEP program_files`**:
      * Searches for files within all `Programs` directories related to the project and engine (e.g., UnrealBuildTool, AutomationTool).
      * Useful for investigating the code of build tools.
  * **`:UEP tree`**:
      * Only works if `neo-tree-unl.nvim` is installed.
      * Opens a full logical tree in `neo-tree`, including "Game", "Plugins", and "Engine" categories for the entire project.
  * **`:UEP module_tree [ModuleName]`**:
      * Only works if `neo-tree-unl.nvim` is installed.
      * If `ModuleName` is provided, it displays a tree rooted at that module only.
      * If run without arguments, it displays a picker UI to select from all modules in the project.
  * **`:UEP grep [Scope]`**:
      * LiveGreps the entire project and engine source code (requires ripgrep).
      * `Scope` can be `Game` (default) or `Engine` to limit the search area.
      * `Game`: Searches only your project's source files and plugins.
      * `Engine`: In addition to project code, also searches the associated engine source code.
  * **`:UEP module_grep <ModuleName>`**:
      * Searches for content within the directory of the specified `<ModuleName>`.
      * Provides noise-free results when investigating the implementation of a specific feature.
      * If no module is specified, a picker will be shown to select a module.

## 🤖 API & Automation (Automation Examples)

You can use the `UEP.api` module to integrate with other Neovim configurations.

### Create a keymap for file searching

Create a keymap to quickly search for files in the current project.

```lua
-- in init.lua or keymaps.lua
vim.keymap.set('n', '<leader>pf', function()
  -- The API is simple and clean
  require('UEP.api').files({})
end, { desc = "[P]roject [F]iles" })```

### Integration with Neo-tree

Add a keymap in Neo-tree to open the UEP file finder for the project to which the selected directory belongs.

```lua
-- Example Neo-tree setup
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

          -- Set CWD inside the project before calling the API
          vim.api.nvim_set_current_dir(path)
          require("UEP.api').tree({})
        end,
      },
    },
  },
}
```

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
