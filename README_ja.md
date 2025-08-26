# UEP.nvim

# Unreal Engine Project Explorer 💓 Neovim

<table>
  <tr>
   <td><div align=center><img width="100%" alt="UCM New Class Interactive Demo" src="https://raw.githubusercontent.com/taku25/UEP.nvim/images/assets/uep_refresh.gif" /></div></td>
   <td><div align=center><img width="100%" alt="UCM Rename Class Interactive Demo" src="https://raw.githubusercontent.com/taku25/UEP.nvim/images/assets/uep_tree.gif" /></div></td>
  </tr>
</table>

`UEP.nvim`は、Unreal Engineプロジェクトの構造を理解し、ナビゲートし、管理するために設計されたNeovimプラグインです。プロジェクト全体のモジュールとファイル情報を非同期で解析・キャッシュし、非常に高速でインテリジェントなファイルナビゲーション体験を提供します。

これは **Unreal Neovim Plugin Stack** の中核をなすプラグインであり、ライブラリとして [UNL.nvim](https://github.com/taku25/UNL.nvim) に依存しています。

[UBT](https://github.com/taku25/UBT.nvim)を使うとBuildやGenerateClangDataBaseなどを非同期でNeovim上から使えるようになります
[UCM](https://github.com/taku25/UCM.nvim)を使うとクラスの追加や削除がNeovim上からできるようになります。

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
  * **モジュール単体のファイルツリー表示**:
      * `:UEP tree`コマンドは、関連するすべてのモジュールのルートを、[Neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim)のようなファイラープラグインで単一の統一されたツリーとして表示できます。



## 🔧 必要要件 (Requirements)

  * Neovim v0.11.3 以上
  * [**UNL.nvim**](https://www.google.com/search?q=https://github.com/taku25/UNL.nvim) (**必須**)
  * [fd](https://github.com/sharkdp/fd) (**プロジェクトのスキャンに必須**)
  * **オプション (UI体験の向上のために、いずれかの導入を強く推奨):**
      * [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
      * [fzf-lua](https://github.com/ibhagwan/fzf-lua)
      * [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) (`:UEP filer`コマンドでマルチルート機能を使う場合に推奨)

## 🚀 インストール (Installation)

お好みのプラグインマネージャーでインストールしてください。

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  'taku25/UEP.nvim',
  -- UNL.nvim は必須の依存関係です
  dependencies = { 'taku25/UNL.nvim' },
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
:UEP files[!] [Game|Engine|All] [--no-deps|--all-deps]

" 特定のモジュールに属するファイルを検索します。
:UEP module_files[!] [ModuleName]

" 既知のプロジェクト一覧をUIで表示し、選択したプロジェクトにカレントディレクトリを変更します。
:UEP cd

" プロジェクトを既知のプロジェクトリストから削除します（ファイルは削除しません）。
:UEP delete

" モジュールルートをファイラーで開きます。
:UEP tree
```

### コマンド詳細

  * **`:UEP refresh`**:
      * `Game` (デフォルト): 現在のゲームプロジェクトのモジュールのみをスキャンします。リンクされたエンジンのキャッシュがない場合は、先にエンジンが自動でスキャンされます。
      * `Engine`: リンクされたエンジンのモジュールのみをスキャンします。
  * **`:UEP files[!]`**:
      * `!`なし: 既存のキャッシュデータからファイルを選択します
      * `!`あり: キャッシュを削除して新しいキャッシュを作成してからファイルを選択します
      * `[Game|Engine]` (デフォルト `Game`): 検索対象とするモジュールのスコープです。
      * `[--no-deps|--all-deps]` (デフォルト `--no-deps`):
          * `--no-deps`: 指定されたスコープのモジュール内のみを検索します。
          * `--all-deps`: 依存関係にある全てのモジュールを検索対象に含めます（`deep_dependencies`を使用）。
  * **`:UEP module_files[!]`**:
      * `!`なし: 既存のキャッシュを使って指定されたモジュールのファイルを検索します。
      * `!`あり: 検索前に、指定されたモジュールのファイルキャッシュのみを軽量に更新します。

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