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

[English](README.md) | [日本語 (Japanese)](README_ja.md)

-----

## ✨ Features

  * **Fast Asynchronous Caching**:
      * Scans the entire project (game and linked engine modules) in the background without blocking the UI.
      * Intelligently separates game and engine caches, maximizing efficiency by allowing multiple projects to share a single engine cache.
      * Ensures the file list is always in sync with the module structure through a `generation` hash system.
  * **Powerful File Searching**:
      * Provides a flexible `:UEP files` command to find your most-used source and config files instantly.
      * **High-Performance Filtering**: If you provide search keywords as arguments (e.g., `:UEP files Game MyActor`), filtering is performed on the server side beforehand, allowing instant results even in large-scale projects.
      * Offers specialized commands for targeted searches within a single module (`:UEP module_files`).
      * Allows filtering files by scope (**Game**, **Engine**, **Runtime**, **Editor**, **Full**).
      * Supports including module dependencies in the search (**--no-deps**, **--shallow-deps**, **--deep-deps**).
      * Instantly search for all classes, structs, or enums within the specified scope (:UEP classes, :UEP structs, :UEP enums).
  * **Intelligent Code Navigation**:
      * The `:UEP find_derived` command instantly finds all child classes that inherit from a specified base class.
      * The `:UEP find_parents` command displays the entire inheritance chain from a specified class up to `UObject`.
      * The `:UEP add_include` command automatically finds and inserts the correct `#include` directive for a class name under the cursor or one chosen from a list.
      * The `:UEP find_module` command allows you to select a class from a list and copies the name of the module it belongs to (e.g., "Core", "Engine") to the clipboard, making it easy to edit `Build.cs`.
      * Leverages the class inheritance data cached by `:UEP refresh` for high-speed navigation.
  * **Intelligent File Watching**:
      * The `:UEP start` command starts monitoring the project for changes.
      * It automatically compares the current VCS (Git) revision with the last cached state.
      * If changes are detected (or on first run), it triggers a `:UEP refresh` automatically, then begins a low-overhead file watcher.
  * **Intelligent Content Searching (Grep)**:
      * Performs high-speed content searches across the entire project and engine source code (requires ripgrep).
      * The `:UEP grep` command lets you specify the search scope (**Game**, **Engine**, **Runtime**, **Editor**, **Full**).
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
          * [**UNX.nvim**](https://github.com/taku25/UNX.nvim) (**Required** for `:UEP tree` and `:UEP module_tree` commands)


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
````

## ⚙️ Configuration

This plugin is configured through the setup function of its library, `UNL.nvim`. However, you can also pass `opts` directly to `UEP.nvim` to configure settings in the `UEP` namespace.

Below are the default values related to `UEP.nvim`.

```lua
-- Place inside the spec for UEP.nvim or UNL.nvim in lazy.nvim
opts = {
  -- UEP-specific settings
  uep = {
    -- Automatically start Neovim server (named pipe) on :UEP start
    server = {
      enable = true,
      name = "UEP_nvim", -- \\.\pipe\UEP_nvim on Windows
    },
    -- Command template for opening files in external IDEs
    ide = {
      -- {file} and {line} will be replaced with actual values
      open_command = "rider --line {line} \"{file}\"",
    },
  },
  

  -- Directory names to search for files during tree construction
  include_directory = { "Source", "Plugins", "Config", },

  -- Folder names to exclude during tree construction
  excludes_directory  = { "Intermediate", "Binaries", "Saved" },

  -- File extensions to be scanned by the ':UEP refresh' command
  files_extensions = {
    "cpp", "h", "hpp", "inl", "ini", "cs",
  },

  -- Manually specify the engine path if automatic detection fails.
  -- Example: "C:/Program Files/Epic Games/UE_5.4"
  engine_path = nil,

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
:UEP files[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" Search for files belonging to a specific module.
:UEP module_files[!] [ModuleName]

" LiveGrep across the project or engine source code.
:UEP grep [Game|Engine|Runtime|Editor|Full]

" LiveGrep files belonging to a specific module.
:UEP module_grep [ModuleName]

" Open an include file by searching the project cache.
:UEP open_file [Path]

" Find and insert an #include directive for a class.
:UEP add_include[!] [ClassName]

" Delete ALL structural (*.project.json) and file (*.files.json) caches for the current project.
:UEP cleanup

" Find derived classes. Use [!] to open the base class picker.
:UEP find_derived[!] [ClassName]

" Find the inheritance chain. Use [!] to open the starting class picker.
:UEP find_parents[!] [ClassName]

" Search for C++ classes (use '!' to refresh cache).
:UEP classes[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" Search for C++ structs (use '!' to refresh cache).
:UEP structs[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" Search for C++ enums (use '!' to refresh cache).
:UEP enums[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" Display the logical tree for the entire project (requires neo-tree-unl.nvim).
:UEP tree

" Display the logical tree for a specific module (requires neo-tree-unl.nvim).
:UEP module_tree [ModuleName]

" Close the UEP tree and clear its expanded state.
:UEP close_tree

" Display a list of known projects in a UI and change the current directory to the selected project.
:UEP cd

" Remove a project from the list of known projects (does not delete files).
:UEP delete

" Create a new Unreal Engine project from a template.
:UEP new_project

" Start project monitoring. Checks for Git updates, runs refresh if needed, then watches for file changes.
:UEP start

" Stop the project monitor.
:UEP stop

" Jumps to the actual class or struct definition file, skipping forward declarations.
:UEP goto_definition[!] [ClassName]

" Select a class first, then select a symbol (function/property) within it to jump.
:UEP class_symbol[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" Open the file location in the system file explorer.
:UEP system_open[!] [Path]

" Jumps to the parent class definition of the current function.
:UEP goto_super_def

" Jumps to the parent class implementation of the current function.
:UEP goto_super_impl

" Override a virtual function from the parent class hierarchy.
:UEP implement_virtual

" Find the module name for a class and copy it to the clipboard.
:UEP find_module[!]

" Open the Build.cs file for the current module. Use '!' to list all modules.
:UEP build_cs[!]

" Open the Target.cs file. Use '!' to include Engine targets.
:UEP target_cs[!]

" Search Unreal Engine Web Docs. Use '!' to pick a class.
:UEP web_doc[!]

" Search for shader files (.usf, .ush).
:UEP shaders[!] [Game|Engine|Runtime|Editor|Full]

" Open the current file in an external IDE (Rider, VS, etc.).
:UEP open_in_ide
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
  * **`:UEP new_project`**:
      * Creates a new Unreal Engine project by copying an existing template from the installed engine's `Templates` directory.
      * Provides an interactive wizard to select:
          1.  Engine Version (auto-detected from Windows Registry).
          2.  Template (e.g., `TP_FirstPerson`, `TP_ThirdPerson`).
          3.  Project Name.
      * Automatically performs recursive file copying, renaming, and string replacement (e.g., changing `TP_FirstPerson` to `MyNewProject` in source files).
      * Configures the `.uproject` file with the correct `EngineAssociation`.
  * **`:UEP files[!]`**:
      * Without `!`: Selects files from the existing cache data.
      * With `!`: Deletes the cache and creates a new one before selecting files.
      * `[Game|Engine|Runtime|Editor|Full]` (default `runtime`): The scope of modules to search.
      * `[--no-deps|--shallow-deps|--deep-deps]` (default `--deep-deps`):
          * `--no-deps`: Searches only within the modules of the specified scope.
          * `--shallow-deps`: Includes direct dependencies.
          * `--deep-deps`: Includes all dependencies (`deep_dependencies`).
      * `[mode=source|config|shader|programs|build_cs|target_cs]`: (Optional) Filter by file type.
  * **`:UEP module_files[!]`**:
      * Without `!`: Searches for files in the specified module using the existing cache.
      * With `!`: Performs a lightweight update of the file cache for only the specified module before searching.
  * **`:UEP program_files`**:
      * Searches for files within all `Programs` directories related to the project and engine (e.g., UnrealBuildTool, AutomationTool).
      * Useful for investigating the code of build tools.
  * **`:UEP config_files`**:
      * Searches for all configuration files (.ini) across the project and engine.
  * **`:UEP tree`**:
      * Only works if `neo-tree-unl.nvim` is installed.
      * Opens a full logical tree in `neo-tree`, including "Game", "Plugins", and "Engine" categories for the entire project.
      * Clears any previously saved expanded state.
  * **`:UEP module_tree [ModuleName]`**:
      * Only works if `neo-tree-unl.nvim` is installed.
      * If `ModuleName` is provided, it displays a tree rooted at that module only.
      * If run without arguments, it displays a picker UI to select from all modules in the project.
      * Clears any previously saved expanded state.
  * **`:UEP close_tree`**:
      * Closes the `neo-tree` window (if open) and clears UEP's internal cache of which nodes were expanded.
      * This ensures that the next `:UEP tree` or `:UEP module_tree` command starts with a fully collapsed view.
  * **`:UEP grep [Scope]`**:
      * LiveGreps the entire project and engine source code (requires ripgrep).
      * `Scope` can be `Game`, `Engine`, `Runtime` (default), `Editor`, or `Full`.
      * `Game`: Searches only your project's source files and plugins.
      * `Engine`: Searches *only* the associated engine source code.
      * `Full` / `Runtime` / `Editor` / `Developer`: Searches both project and engine code.
  * **`:UEP module_grep <ModuleName>`**;
      * Searches for content within the directory of the specified `<ModuleName>`.
      * Provides noise-free results when investigating the implementation of a specific feature.
      * If no module is specified, a picker will be shown to select a module.
  * **`:UEP program_grep`**:
      * Performs a live grep for files within all `Programs` directories related to the project and engine.
      * Useful for investigating the code of build tools and automation scripts.
  * **`:UEP config_grep [Scope]`**:
      * LiveGreps for content within `.ini` configuration files.
      * `Scope` can be `Game`, `Engine`, or `Full` (default `runtime`, which aliases to `Full`).
  * **`:UEP open_file [Path]`**:
      * Finds and opens a file based on an include path, either extracted automatically from the text on the current line or explicitly provided by `[Path]`.
      * It performs an **intelligent hierarchical search** within the project cache (checking current file directory, module Public/Private folders, dependency modules, etc.).
  * **`:UEP add_include[!] [ClassName]`**:
      * Finds and inserts the correct `#include` directive for a C++ class.
      * Without `!`: Uses the `[ClassName]` argument if provided, otherwise it uses the word under the cursor.
      * With `!`: Ignores arguments and the word under the cursor, and always opens a picker UI to select a class from the entire project.
      * **Intelligently places the include directive**: In header files (`.h`), it is inserted before the `.generated.h` line. In source files (`.cpp`), it is inserted after the last existing `#include` statement.
  * **`:UEP find_derived[!] [ClassName]`**: Searches for all classes that inherit from a specified base class.
      * Without `!`: Uses the `[ClassName]` argument if provided, otherwise it uses the word under the cursor.
      * With `!`: Ignores arguments and opens a picker UI to select a base class from the entire project.
  * **`:UEP find_parents[!] [ClassName]`**: Displays the inheritance chain for a specified class.
      * Without `!`: Uses the `[ClassName]` argument if provided, otherwise it uses the word under the cursor.
      * With `!`: Ignores arguments and opens a picker UI to select the starting class.
  * **`:UEP classes[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]`**: Opens a picker to select and jump to the definition of a C++ class.
      * Flags: Controls cache regeneration and scope filtering.
      * Scope: Default is **`runtime`**.
      * Deps: Default is **`--deep-deps`**.
  * **`:UEP structs[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]`**: Opens a picker to select and jump to the definition of a C++ struct.
      * Flags: Controls cache regeneration and scope filtering.
      * Scope: Default is **`runtime`**.
      * Deps: Default is **`--deep-deps`**.
  * **`:UEP enums[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]`**: Opens a picker to select and jump to the definition of a C++ enum.
      * Flags: Controls cache regeneration and scope filtering.
      * Scope: Default is **`runtime`**.
      * Deps: Default is **`--deep-deps`**.
  * **`:UEP purge [ComponentName]`**:
      * Deletes only the **file cache** (`*.files.json`) for the specified Game, Engine, or Plugin component.
      * This allows forcing a file rescan without re-analyzing the project's dependency structure.
  * **`:UEP cleanup`**:
      * **DANGEROUS**: Permanently deletes **ALL** structural caches (`*.project.json`) and **ALL** file caches (`*.files.json`) associated with the current project, including all plugins and the linked engine.
      * The command runs asynchronously with a progress bar and requires confirmation.
      * After running this, you **must** run `:UEP refresh` to rebuild the project structure from scratch.
  * **`:UEP goto_definition[!] [ClassName]`**: Jumps to the actual definition file of a class, skipping forward declarations.
      * Without `!`: Uses the `[ClassName]` argument if provided, otherwise it uses the word under the cursor. It performs an **intelligent hierarchical search** based on the current module's dependencies (current component -\> shallow deps -\> deep deps) before falling back to LSP.
      * With `!`: Ignores arguments and the word under the cursor, and always opens a picker UI to select a class from the entire project.
  * **`:UEP class_symbol[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]`**:
      * Opens a two-step picker: first select a class from the project, then select a symbol (function or property) within that class to jump to.
      * This command leverages UEP for global class searching and delegates to UCM for detailed symbol parsing of the selected file.
      * Flags: Controls cache regeneration (`!`) and scope/dependency filtering.
  * **`:UEP system_open[!] [Path]`**:
      * Opens the location of the specified file in the OS file explorer (Explorer/Finder/xdg-open).
      * `!` (Bang): Ignores arguments/current buffer and opens a picker UI to select a file from the entire project cache.
      * `[Path]`: Optional path. If omitted and no `!`, opens the directory of the current file.
  * **`:UEP goto_super_def`**:
      * Jumps to the definition (header file) of the parent class's function that corresponds to the current function under the cursor.
      * Intelligently resolves the inheritance chain using cached project data.
  * **`:UEP goto_super_impl`**:
      * Jumps to the implementation (source file) of the parent class's function.
      * Falls back to the header definition if the source file is not found.
  * **`:UEP implement_virtual [ClassName]`**:
      * Lists all overrideable virtual functions from the parent class hierarchy.
      * Selecting a function automatically inserts the declaration into the header file and copies the implementation stub to the clipboard.
      * Must be executed within a header file.
  * **`:UEP find_module[!]`**:
      * Opens a picker UI to select a class, struct, or enum from the entire project.
      * Selecting an item copies the name of the module it belongs to (e.g., `"Core"`, `"UMG"`) to the system clipboard.
      * This is extremely useful when adding dependencies to `Build.cs`.
      * Use `!` to force a cache refresh before opening the picker.
  * **`:UEP build_cs[!]`**:
      * Without `!`: Opens the `Build.cs` file corresponding to the module of the current file. If the module cannot be determined, it falls back to the picker.
      * With `!`: Displays a picker to select from all `Build.cs` files in the project.
  * **`:UEP target_cs[!]`**:
      * Without `!`: Displays a list of `Target.cs` files in the current project (Game/Plugins) for selection. If there is only one target, it opens immediately.
      * With `!`: Includes `Target.cs` files from the Engine in the list.
  * **`:UEP web_doc` / `:UEP web_doc!`**:
      * Opens the Unreal Engine Web Documentation in your browser.
      * Without `!`: Searches for the word under the cursor.
      * With `!`: Opens a picker to select a class from the project.
      * **Note (Experimental)**: The logic for generating direct URLs (especially for Plugins) is currently in beta and may not be 100% accurate. In such cases, it falls back to a site-specific search.
  * **`:UEP shaders[!] [Scope]`**:
      * Searches for shader files (`.usf`, `.ush`) within the specified scope (default `Full`).
      * Useful for quickly accessing engine or project shaders.
  * **`:UEP open_in_ide`**:
      * Opens the current file at the current line in an external IDE configured in `uep.ide.open_command`.
      * Defaults to Rider, but can be configured for VS Code, Visual Studio, etc.
  * **Neovim Server (Named Pipe)**:
      * When `:UEP start` is executed, UEP automatically starts a Neovim server.
      * This allows external tools (like Rider/VS) to send commands back to Neovim.
      * A helper script `scripts/open_in_uep.ps1` is provided to facilitate this integration.
## 🤖 API & Automation Examples

You can use the `UEP.api` module to integrate with other Neovim configurations.

### Keymap Examples

Create keymaps to quickly perform common tasks.

#### Open File

Enhance the built-in `gf` command to use UEP's intelligent file searching for includes.

```lua
-- in init.lua or keymaps.lua
vim.keymap.set('n', 'gf', require('UEP.api').open_file, { noremap = true, silent = true, desc = "UEP: Open include file" })
```

#### Add Include

Quickly add an \#include directive for the class under the cursor.

```lua
-- in init.lua or keymaps.lua
vim.keymap.set('n', '<leader>ai', require('UEP.api').add_include, { noremap = true, silent = true, desc = "UEP: Add #include directive" })
```

#### File Search

Create a keymap to quickly search for files in the current project.

```lua
-- in init.lua or keymaps.lua
vim.keymap.set('n', '<leader>pf', function()
  -- The API is simple and clean
  require('UEP.api').files({})
end, { desc = "UEP: [P]roject [F]iles" })
```

#### Go to Definition (UEP)

Use UEP's intelligent definition jump, complementing LSP's default jump.

```lua
-- in init.lua or keymaps.lua
-- Use standard 'gd' for LSP
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { desc = "LSP Definition" })
-- Use <leader><C-]> for UEP's enhanced definition jump (cursor word)
vim.keymap.set('n', '<leader><C-]>', function() require('UEP.api').goto_definition({ has_bang = false }) end, { noremap = true, silent = true, desc = "UEP: Go to Definition (Cursor)" })
-- Optional: Use <leader>gD for UEP's definition jump via picker
vim.keymap.set('n', '<leader>gD', function() require('UEP.api').goto_definition({ has_bang = true }) end, { noremap = true, silent = true, desc = "UEP: Go to Definition (Picker)" })
```

### Integration with Neo-tree

Add a keymap in Neo-tree to open the UEP logical tree for the project to which the selected directory belongs.

```lua
-- Example Neo-tree setup
opts = {
  filesystem = {
    window = {
      mappings = {
        ["<leader>pt"] = function(state)
          -- Get the directory of the currently selected node
          local node = state.tree:get_node()
          local path = node:get_id()
          if node.type ~= "directory" then
            path = require("vim.fs").dirname(path)
          end

          -- Set CWD inside the project before calling the API
          vim.api.nvim_set_current_dir(path)
          require("UEP.api").tree({})
        end,
      },
    },
  },
}
```

## Others

**Unreal Engine Related Plugins:**

  * [**UnrealDev.nvim**](https://github.com/taku25/UnrealDev.nvim)
      * **Recommended:** An all-in-one suite to install and manage all these Unreal Engine related plugins at once.
  * [**UNX.nvim**](https://github.com/taku25/UNX.nvim)
      * **Standard:** A dedicated explorer and sidebar optimized for Unreal Engine development. It visualizes project structure, class hierarchies, and profiling insights without depending on external file tree plugins.
  * [UEP.nvim](https://github.com/taku25/UEP.nvim)
      * Analyzes .uproject to simplify file navigation.
  * [UEA.nvim](https://github.com/taku25/UEA.nvim)
      * Finds Blueprint usages of C++ classes.
  * [UBT.nvim](https://github.com/taku25/UBT.nvim)
      * Use Build, GenerateClangDataBase, etc., asynchronously from Neovim.
  * [UCM.nvim](https://github.com/taku25/UCM.nvim)
      * Add or delete classes from Neovim.
  * [ULG.nvim](https://github.com/taku25/ULG.nvim)
      * View UE logs, LiveCoding, stat fps, etc., from Neovim.
  * [USH.nvim](https://github.com/taku25/USH.nvim)
      * Interact with ushell from Neovim.
  * [USX.nvim](https://github.com/taku25/USX.nvim)
      * Plugin for highlight settings for tree-sitter-unreal-cpp and tree-sitter-unreal-shader.
  * [neo-tree-unl](https://github.com/taku25/neo-tree-unl.nvim)
      * Integration for [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) users to display an IDE-like project explorer.
  * [tree-sitter for Unreal Engine](https://github.com/taku25/tree-sitter-unreal-cpp)
      * Provides syntax highlighting using tree-sitter, including UCLASS, etc.
  * [tree-sitter for Unreal Engine Shader](https://github.com/taku25/tree-sitter-unreal-shader)
      * Provides syntax highlighting for Unreal Shaders like .usf, .ush.

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
