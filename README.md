はい、承知いたしました。
あなたが更新してくれた、より洗練された `README_ja.md` を、自然でプロフェッショナルな英語に翻訳します。

これが、`UEP.nvim` のための `README.md` (English) の最終・完成版です。

---

# UEP.nvim

# Unreal Engine Project Explorer 💓 Neovim

<table>
  <tr>
   <td><div align=center><img width="100%" alt="UEP Refresh Demo" src="https://raw.githubusercontent.com/taku25/UEP.nvim/images/assets/uep_refresh.gif" /></div></td>
   <td><div align=center><img width="100%" alt="UEP Logical Tree Demo" src="https://raw.githubusercontent.com/taku25/UEP.nvim/images/assets/uep_tree.gif" /></div></td>
  </tr>
</table>

`UEP.nvim` is a Neovim plugin designed to understand, navigate, and manage Unreal Engine projects. It asynchronously parses and caches module and file information for the entire project, providing an exceptionally fast and intelligent file navigation experience.

This is a core plugin of the **Unreal Neovim Plugin Sweet**, and it depends on [UNL.nvim](https://github.com/taku25/UNL.nvim) as a library.

*   Use [UBT.nvim](https://github.com/taku25/UBT.nvim) to run tasks like Build and GenerateClangDataBase asynchronously from within Neovim.
*   Use [UCM.nvim](https://github.com/taku25/UCM.nvim) to add or remove classes from within Neovim.
*   Use [neo-tree-unl.nvim](https://github.com/taku25/neo-tree-unl.nvim) to display an IDE-like project explorer.

[English](README.md) | [日本語 (Japanese)](README_ja.md)

-----

## ✨ Features

  * **Fast Asynchronous Caching**:
      * Scans the entire project (both the game and its linked engine modules) in the background without blocking the UI.
      * Intelligently separates game and engine caches, allowing multiple projects to share a single engine cache for maximum efficiency.
      * A `generation` hash system ensures that the file list is always in sync with the module structure.
  * **Powerful File Searching**:
      * Provides a flexible `:UEP files` command to find files instantly.
      * Allows filtering files by scope (**Game**, **Engine**).
      * Supports including module dependencies (**shallow** `dependencies` or **deep** `dependencies`) in the search.
  * **UI Integration**:
      * Leverages the UI abstraction layer of `UNL.nvim` to automatically use UI frontends like [Telescope](https://github.com/nvim-telescope/telescope.nvim) or [fzf-lua](https://github.com/ibhagwan/fzf-lua).
      * Falls back to Neovim's native UI if no supported UI plugin is installed.
  * **IDE-like Logical Tree View**:
      * Integrates with **[neo-tree-unl.nvim](https://github.com/taku25/neo-tree-unl.nvim)** to provide a logical tree view similar to a solution explorer in an IDE.
      * The `:UEP tree` command gives a bird's-eye view of the entire project structure (Game, Plugins, Engine).
      * The `:UEP module_tree` command switches to a focused view on a single module.
      * Running `:UEP refresh` automatically updates the open tree view to the latest state.

## 🔧 Requirements

  * Neovim v0.8+
  * [**UNL.nvim**](https://github.com/taku25/UNL.nvim) (**Required**)
  * [fd](https://github.com/sharkdp/fd) (**Required for project scanning**)
  * **Optional (Strongly recommended for the best UI experience):**
      * **UI (Picker):**
          * [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
          * [fzf-lua](https://github.com/ibhagwan/fzf-lua)
      * **UI (Tree View):**
          * [**neo-tree.nvim**](https://github.com/nvim-neo-tree/neo-tree.nvim)
          * [**neo-tree-unl.nvim**](https://github.com/taku25/neo-tree-unl.nvim) (**Required** to use the `:UEP tree` and `:UEP module_tree` commands)

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
    -- Any UEP-specific settings would go here
  },
}
```

## ⚙️ Configuration

This plugin is configured through the setup function of its library, `UNL.nvim`. However, you can also configure `UEP` namespace settings by passing `opts` directly to the `UEP.nvim` spec.

The following are the default values related to `UEP.nvim`.

```lua
-- Place inside the spec for UEP.nvim or UNL.nvim in lazy.nvim
opts = {
  -- UEP-specific settings
  uep = {
    -- Section for future UEP-specific settings
  },

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
" Rescan the project and update the cache. This is the most important command.
:UEP refresh [Game|Engine]

" Open a UI to search for files with various conditions.
:UEP files[!] [Game|Engine] [--all-deps]

" Search for files belonging to a specific module.
:UEP module_files[!] [ModuleName]

" Display a logical view of the entire project (requires neo-tree-unl.nvim)
:UEP tree

" Display a logical view of a single module (requires neo-tree-unl.nvim)
:UEP module_tree [ModuleName]

" Show a UI list of known projects and change the current directory to the selected one.
:UEP cd

" Remove a project from the list of known projects (does not delete files).
:UEP delete
```

### Command Details

  * **`:UEP refresh`**:
      * `Game` (default): Scans only the modules of the current game project. If a linked engine cache does not exist, the engine will be scanned automatically first.
      * `Engine`: Scans only the modules of the linked engine.
  * **`:UEP files[!]`**:
      * Without `!`: Selects files from the existing cache data.
      * With `!`: Deletes the cache and creates a new one before selecting files.
      * `[Game|Engine]` (default `Game`): The scope of modules to search.
      * `[--all-deps]` (default behavior is shallow dependencies):
          * shallow: Searches only within the modules of the specified scope.
          * `--all-deps`: Includes all dependent modules in the search (uses `deep_dependencies`).
  * **`:UEP module_files[!]`**:
      * Without `!`: Uses the existing cache to search for files in the specified module.
      * With `!`: Performs a lightweight update of the file cache for only the specified module before searching.
  * **`:UEP tree`**:
      * Only works if `neo-tree-unl.nvim` is installed.
      * Opens a complete logical tree in `neo-tree`, including the "Game," "Plugins," and "Engine" categories for the entire project.
  * **`:UEP module_tree [ModuleName]`**:
      * Only works if `neo-tree-unl.nvim` is installed.
      * If `ModuleName` is passed as an argument, it displays a tree rooted at that module.
      * If run without arguments, it displays a picker UI to select a module from the project.

## 🤖 API & Automation Examples

You can use the `UEP.api` module to integrate with other Neovim configurations.

### Create a Keymap for File Searching

Create a keymap to quickly search for files in the current project.

```lua
-- in your init.lua or keymaps.lua
vim.keymap.set('n', '<leader>pf', function()
  -- The API is simple and clean
  require('UEP.api').files({})
end, { desc = "[P]roject [F]iles" })
```
*(The `Neo-treeとの連携` section was removed as the new recommended way is via the `:UEP tree` command)*

## 📜 ライセンス (License)

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