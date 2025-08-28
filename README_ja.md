# UEP.nvim

# Unreal Engine Project Explorer 💓 Neovim

<table>
  <tr>
   <td><div align=center><img width="100%" alt="UCM New Class Interactive Demo" src="https://raw.githubusercontent.com/taku25/UEP.nvim/images/assets/uep_refresh.gif" /></div></td>
   <td><div align=center><img width="100%" alt="UCM Rename Class Interactive Demo" src="https://raw.githubusercontent.com/taku25/UEP.nvim/images/assets/uep_tree.gif" /></div></td>
  </tr>
</table>

`UEP.nvim`は、Unreal Engineプロジェクトの構造を理解し、ナビゲートし、管理するために設計されたNeovimプラグインです。プロジェクト全体のモジュールとファイル情報を非同期で解析・キャッシュし、非常に高速でインテリジェントなファイルナビゲーション体験を提供します。

これは **Unreal Neovim Plugin sweet** の中核をなすプラグインであり、ライブラリとして [UNL.nvim](https://github.com/taku25/UNL.nvim) に依存しています。

[UBT](https://github.com/taku25/UBT.nvim)を使うとBuildやGenerateClangDataBaseなどを非同期でNeovim上から使えるようになります
[UCM](https://github.com/taku25/UCM.nvim)を使うとクラスの追加や削除がNeovim上からできるようになります。
[neo-tree-unl](https://github.com/taku25/neo-tree-unl.nvim)を使うとIDEのようなプロジェクトエクスプローラーを表示できます。


[English](README.md) | [日本語 (Japanese)](README_ja.md)

-----

## ✨ 機能 (Features)

  * **高速な非同期キャッシング**:
      * UIをブロックすることなく、プロジェクト全体（ゲームおよびリンクされたエンジンモジュール）をバックグラウンドでスキャンします。
      * ゲームとエンジンのキャッシュを賢く分離し、複数のプロジェクトが単一のエンジンキャッシュを共有できるため、効率が最大化されます。
      * `generation`ハッシュシステムにより、ファイルリストが常にモジュール構造と同期していることを保証します。
  * **強力なファイル検索**:
      * ファイルを即座に見つけるための柔軟な`:UEP files`コマンドを提供します。
      * スコープ（**Game**, **Engine**, **All**）でファイルをフィルタリングできます。
      * モジュールの依存関係（**--no-deps** `dependencies`または**--all-deps** `dependencies`）を検索に含めることが可能です。
  * **UI統合**:
      * `UNL.nvim`のUI抽象化レイヤーを活用し、[Telescope](https://github.com/nvim-telescope/telescope.nvim)や[fzf-lua](https://github.com/ibhagwan/fzf-lua)のようなUIフロントエンドを自動的に使用します。
      * UIプラグインがインストールされていない場合でも、NeovimネイティブのUIにフォールバックします。
  * **IDEライクな論理ツリービュー**:
      * **[neo-tree-unl.nvim](https://github.com/taku25/neo-tree-unl.nvim)** との連携により、IDEのソリューションエクスプローラーのような論理的なツリービューを提供します。
      * `:UEP tree`コマンドで、プロジェクト全体の構造（Game, Plugins, Engine）を俯瞰できます。
      * `:UEP module_tree`コマンドで、単一のモジュールのみにフォーカスしたビューに切り替えられます。
      * `:UEP refresh`を実行すると、開いているツリーが自動的に最新の状態に更新されます。



## 🔧 必要要件 (Requirements)

  * Neovim v0.11.3 以上
  * [**UNL.nvim**](https://www.google.com/search?q=https://github.com/taku25/UNL.nvim) (**必須**)
  * [fd](https://github.com/sharkdp/fd) (**プロジェクトのスキャンに必須**)
  * **オプション (完全な体験のために、導入を強く推奨):**
      * **UI (Picker):**
          * [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
          * [fzf-lua](https://github.com/ibhagwan/fzf-lua)
      * **UI (Tree View):**
          * [**neo-tree.nvim**](https://github.com/nvim-neo-tree/neo-tree.nvim)
          * [**neo-tree-unl.nvim**](https://github.com/taku25/neo-tree-unl.nvim) (`:UEP tree`, `:UEP module_tree` コマンドの利用に**必須**)


## 🚀 インストール (Installation)

お好みのプラグインマネージャーでインストールしてください。

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  'taku25/UEP.nvim',
  -- UNL.nvim は必須の依存関係です
  dependencies = {
     'taku25/UNL.nvim',
     'nvim-telescope/telescope.nvim', --オプション
  },
  -- 全ての設定はUNL.nvimから継承されますが、ここで上書きも可能です
  opts = {
    -- UEP固有の設定があればここに記述します
  },
}
```

## ⚙️ 設定 (Configuration)

このプラグインは、ライブラリである`UNL.nvim`のセットアップ関数を通じて設定されます。ただし、`UEP.nvim`に直接`opts`を渡すことで、`UEP`名前空間の設定を行うことも可能です。

以下は`UEP.nvim`に関連するデフォルト値です。

```lua
-- lazy.nvimのUEP.nvimまたはUNL.nvimのspec内に記述
opts = {
  -- UEP固有の設定
  uep = {
    -- 将来的なUEP固有設定のためのセクション
  },

  -- ':UEP refresh' コマンドによってスキャンされるファイルの拡張子
  files_extensions = {
    "cpp", "h", "hpp", "inl", "ini", "cs",
  },

  -- UIバックエンドの設定 (UNL.nvimから継承)
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

## ⚡ 使い方 (Usage)

すべてのコマンドは`:UEP`から始まります。

```viml
" プロジェクトを再スキャンしてキャッシュを更新します。これが最も重要なコマンドです。
:UEP refresh [Game|Engine]

" 様々な条件でファイルを検索するためのUIを開きます。
:UEP files[!] [Game|Engine] [--all-deps]

" 特定のモジュールに属するファイルを検索します。
:UEP module_files[!] [ModuleName]

" プロジェクト全体の論理ツリーを表示します (neo-tree-unl.nvim が必要)
:UEP tree

" 特定のモジュールの論理ツリーを表示します (neo-tree-unl.nvim が必要)
:UEP module_tree [ModuleName]

" 既知のプロジェクト一覧をUIで表示し、選択したプロジェクトにカレントディレクトリを変更します。
:UEP cd

" プロジェクトを既知のプロジェクトリストから削除します（ファイルは削除しません）。
:UEP delete
```

### コマンド詳細

(**:UEP refresh**, **:UEP files**, **:UEP module_files** のセクションは変更ありません)

  * **`:UEP tree`**:
      * `neo-tree-unl.nvim` がインストールされている場合にのみ機能します。
      * プロジェクト全体の「Game」「Plugins」「Engine」のカテゴリを含む、完全な論理ツリーを`neo-tree`で開きます。
  * **`:UEP module_tree [ModuleName]`**:
      * `neo-tree-unl.nvim` がインストールされている場合にのみ機能します。
      * `ModuleName`を引数として渡すと、そのモジュールのみをルートとしたツリーが表示されます。
      * 引数なしで実行すると、プロジェクト内の全モジュールを選択するためのピッカーUIが表示されます。
      

## 🤖 API & 自動化 (Automation Examples)

`UEP.api`モジュールを使用して、他のNeovim設定と連携させることができます。

### ファイル検索のキーマップ作成

現在のプロジェクトのファイルを素早く検索するためのキーマップを作成します。

```lua
-- init.lua や keymaps.lua などに記述
vim.keymap.set('n', '<leader>pf', function()
  -- APIはシンプルでクリーンです
  require('UEP.api').files({})
end, { desc = "[P]roject [F]iles" })
```

### Neo-treeとの連携

Neo-treeでキーマップを追加し、選択したディレクトリが属するプロジェクトを対象にUEPファイラーを開きます。

```lua
-- Neo-treeのセットアップ例
opts = {
  filesystem = {
    window = {
      mappings = {
        ["<leader>pf"] = function(state)
          -- 現在選択されているノードのディレクトリを取得
          local node = state.tree:get_node()
          local path = node:get_id()
          if node.type ~= "directory" then
            path = require("vim.fs").dirname(path)
          end

          -- APIを呼ぶ前にCWDをプロジェクト内に設定
          vim.api.nvim_set_current_dir(path)
          require("UEP.api').tree({})
        end,
      },
    },
  },
}
```

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