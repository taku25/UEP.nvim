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

[English](README.md) | [日本語 (Japanese)](README_ja.md)

-----

## ✨ 機能 (Features)

  * **高速な非同期キャッシング**:
      * UIをブロックすることなく、プロジェクト全体（ゲームおよびリンクされたエンジンモジュール）をバックグラウンドでスキャンします。
      * ゲームとエンジンのキャッシュを賢く分離し、複数のプロジェクトが単一のエンジンキャッシュを共有できるため、効率が最大化されます。
      * `generation`ハッシュシステムにより、ファイルリストが常にモジュール構造と同期していることを保証します。
  * **強力なファイル検索**:
      * ファイルを即座に見つけるための柔軟な`:UEP files`コマンドを提供します。
      * スコープ（**Game**, **Engine**, **Runtime**, **Editor**, **Full**）でファイルをフィルタリングできます。
      * モジュールの依存関係（**--no-deps**, **--shallow-deps**, **--deep-deps**）を検索に含めることが可能です。
      * モジュールや`Programs`ディレクトリに特化した検索コマンドを提供します。
      * 指定されたスコープ内の全てのクラス、構造体、またはEnum（列挙型）を即座に検索します（:UEP classes, :UEP structs, :UEP enums）。
  * **インテリジェントなコードナビゲーション**:
      * `:UEP find_derived` コマンドで、指定した基底クラスを継承する全ての子クラスを瞬時に発見します。
      * `:UEP find_parents` コマンドで、指定したクラスから`UObject`に至るまでの全継承チェーンを表示します。
      * `:UEP refresh` によってキャッシュされたクラス継承データを活用し、高速なナビゲーションを実現します。
      * `:UEP add_include` コマンドで、カーソル下のクラス名やリストから選択したクラスの `#include` ディレクティブを自動で挿入します。
      * `:UEP find_module` コマンドで、クラス一覧から選択したクラスが所属するモジュール名（例: "Core", "Engine"）をクリップボードにコピーします。`Build.cs`の編集に便利です。 <-- 追加
  * **インテリジェントなコンテンツ検索 (Grep)**:
      * プロジェクトとエンジンのソースコード全体を横断して、ファイルの中身を高速に検索します (ripgrepが必須)。
      * :UEP grep コマンドで、検索範囲をスコープ (Game, Engine, Runtimeなど) で指定できます。
      * :UEP module_grep コマンドで、特定のモジュール (<module_name>) 内に限定した、ノイズのない集中検索が可能です。
      * :UEP program_grep コマンドで、全ての`Programs`ディレクトリ内に限定した検索が可能です。
      * :UEP config_grep コマンドで、.ini設定ファイル内に限定した検索が可能です。
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
  * [rg](https://github.com/BurntSushi/ripgrep) (**プロジェクトのGrepに必須**)
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
````

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
  

  -- Tree構築時にファイルを検索する ディレクトリ名
  include_directory = { "Source", "Plugins", "Config", },

  -- Tree構築時に排除するフォルダ名
  excludes_directory  = { "Intermediate", "Binaries", "Saved" },

  -- ':UEP refresh' コマンドによってスキャンされるファイルの拡張子
  files_extensions = {
    "cpp", "h", "hpp", "inl", "ini", "cs",
  },

  -- エンジンの自動検出が失敗する場合に、手動でパスを指定します
  -- 例: "C:/Program Files/Epic Games/UE_5.4"
  engine_path = nil,

  -- UIバックエンドの設定 (UNL.nvimから継承)
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

## ⚡ 使い方 (Usage)

すべてのコマンドは`:UEP`から始まります。

```viml
" プロジェクトを再スキャンしてキャッシュを更新します。これが最も重要なコマンドです。
:UEP refresh [Game|Engine]

" 日常的に使うソースや設定ファイルを検索するためのUIを開きます。
:UEP files[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" 特定のモジュールに属するファイルを検索します。
:UEP module_files[!] [ModuleName]

" Programsディレクトリ内のファイルを検索します。
:UEP program_files

" すべてのコンフィグファイル (.ini) を検索します。
:UEP config_files

" プロジェクトまたはエンジンのソースコード全体からLiveGrepします。
:UEP grep [Game|Engine|Runtime|Editor|Full]

" 特定のモジュールに属するファイルをLiveGrepします。
:UEP module_grep [ModuleName]

" Programsディレクトリ内のファイルをLiveGrepします。
:UEP program_grep

" .ini 設定ファイル内をLiveGrepします。
:UEP config_grep [Game|Engine|Full]

" プロジェクトキャッシュを検索して、インクルードファイルを開きます。
:UEP open_file [Path]

" クラスの#includeディレクティブを検索し、挿入します。
:UEP add_include[!] [ClassName]

" 特定のコンポーネント(Game/Engine/Plugin)のファイルキャッシュのみを削除します。
:UEP purge [ComponentName]

" 現在のプロジェクトの全ての構造キャッシュとファイルキャッシュを削除します。
:UEP cleanup

" 派生クラスを検索します。[!]で基底クラスのピッカーを開きます。
:UEP find_derived[!] [ClassName]

" 継承チェーンを検索します。[!]で起点クラスのピッカーを開きます。
:UEP find_parents[!] [ClassName]

" C++クラスを検索します（'!'でキャッシュを強制更新）。
:UEP classes[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" C++構造体を検索します（'!'でキャッシュを強制更新）。
:UEP structs[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" C++ Enum（列挙型）を検索します（'!'でキャッシュを強制更新）。
:UEP enums[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]

" プロジェクト全体の論理ツリーを表示します (neo-tree-unl.nvim が必要)。
:UEP tree

" 特定のモジュールの論理ツリーを表示します (neo-tree-unl.nvim が必要)。
:UEP module_tree [ModuleName]

" UEPツリーを閉じ、展開状態のキャッシュをクリアします。
:UEP close_tree

" 既知のプロジェクト一覧をUIで表示し、選択したプロジェクトにカレントディレクトリを変更します。
:UEP cd

" プロジェクトを既知のプロジェクトリストから削除します（ファイルは削除しません）。
:UEP delete

" 先行宣言をスキップして、クラスや構造体の実際の定義ファイルにジャンプします。
:UEP goto_definition[!] [ClassNam

" プロジェクトキャッシュを検索して、インクルードファイルを開きます。
:UEP open_file [Path]

" 現在の関数の親クラス定義へジャンプします。
:UEP goto_super_def

" 現在の関数の親クラス実装へジャンプします。
:UEP goto_super_impl

" 親クラス階層から仮想関数をオーバーライドします。
:UEP implement_virtual

" クラスが所属するモジュール名を検索し、クリップボードにコピーします。
:UEP find_module[!]

" 現在のモジュールのBuild.csを開きます。[!]で全モジュールから選択します。
:UEP build_cs[!]

" Target.csを開きます。[!]でエンジンを含めた全ターゲットから選択します。
:UEP target_cs[!]

" Unreal EngineのWebドキュメントを検索します。'!'でクラスを選択できます。
:UEP web_doc[!]
```

### コマンド詳細

  * **`:UEP refresh`**:
      * `Game` (デフォルト): 現在のゲームプロジェクトのモジュールのみをスキャンします。リンクされたエンジンのキャッシュがない場合は、先にエンジンが自動でスキャンされます。
      * `Engine`: リンクされたエンジンのモジュールのみをスキャンします。
  * **`:UEP cd`**:
      * UEP が管理しているプロジェクトのルートに移動します
          * refresh時に管理に登録されます
  * **`:UEP delete`**:
      * UEP が管理しているプロジェクトを削除します
          * UEP側の管理から削除されるだけで実際のUEプロジェクトは削除されません
  * **`:UEP files[!]`**:
      * `!`なし: 既存のキャッシュデータからファイルを選択します
      * `!`あり: キャッシュを削除して新しいキャッシュを作成してからファイルを選択します
      * `[Game|Engine|Runtime|Editor|Full]` (デフォルト `runtime`): 検索対象とするモジュールのスコープです。
      * `[--no-deps|--shallow-deps|--deep-deps]` (デフォルト `--deep-deps`):
          * `--no-deps`: 指定されたスコープのモジュール内のみを検索します。
          * `--shallow-deps`: 直接の依存関係にあるモジュールを含めます。
          * `--deep-deps`: 依存関係にある全てのモジュールを検索対象に含めます（`deep_dependencies`を使用）。
  * **`:UEP module_files[!]`**:
      * `!`なし: 既存のキャッシュを使って指定されたモジュールのファイルを検索します。
      * `!`あり: 検索前に、指定されたモジュールのファイルキャッシュのみを軽量に更新します。
  * **`:UEP tree`**:
      * `neo-tree-unl.nvim` がインストールされている場合にのみ機能します。
      * プロジェクト全体の「Game」「Plugins」「Engine」のカテゴリを含む、完全な論理ツリーを`neo-tree`で開きます。
      * 実行時に、以前のツリー展開状態のキャッシュをクリアします。
  * **`:UEP program_files`**:
      * プロジェクトとエンジンに関連する全ての`Programs`ディレクトリ（例: UnrealBuildTool, AutomationTool）内のファイルを検索します。
      * ビルドツールのコードを調査する際に便利です。
  * **`:UEP config_files`**:
      * プロジェクトとエンジンに関連する全てのコンフィグファイル (.ini) を検索します
  * **`:UEP module_tree [ModuleName]`**:
      * `neo-tree-unl.nvim` がインストールされている場合にのみ機能します。
      * `ModuleName`を引数として渡すと、そのモジュールのみをルートとしたツリーが表示されます。
      * 引数なしで実行すると、プロジェクト内の全モジュールを選択するためのピッカーUIが表示されます。
      * 実行時に、以前のツリー展開状態のキャッシュをクリアします。
  * **`:UEP close_tree`**:
      * `neo-tree`ウィンドウを（開いていれば）閉じ、UEPが内部で保持しているノードの展開状態キャッシュをクリアします。
      * これにより、次回の`:UEP tree`または`:UEP module_tree`コマンドが、完全に折りたたまれた状態から開始されるようになります。
  * **`:UEP grep [Scope]`**
      * プロジェクトとエンジンのソースコード全体からLiveGrepします検索します (ripgrepが必須)。
      * Scopeには `Game`, `Engine`, `Runtime` (デフォルト), `Editor`, `Full` を指定でき、検索範囲を限定します。
      * `Game`: あなたのプロジェクトのソースファイルとプラグインのみを検索します。
      * `Engine`: 関連付けられたエンジンのソースコード**のみ**を検索します。
      * `Full` / `Runtime` / `Editor` / `Developer`: プロジェクトとエンジンの両方を検索します。
  * **`:UEP module_grep <ModuleName>`**;
      * 指定された\<ModuleName\>のディレクトリ内に限定して、ファイルの中身を検索します。
      * 特定の機能の実装を深く調査する際に、ノイズのない検索結果を得られます。
      * モジュールを指定しない場合はpickerでモジュールを選択します
  * **`:UEP program_grep`**:
      * プロジェクトとエンジンに関連する全ての`Programs`ディレクトリ内のファイルをLiveGrepします。
      * ビルドツールや自動化スクリプトのコードを調査する際に便利です。
  * **`:UEP config_grep [Scope]`**:
      * `Config`ディレクトリ（`.ini`ファイル）内をLiveGorpします。
      * Scopeには `Game`, `Engine`, `Full` を指定できます (デフォルトは `runtime` で、`Full` と同様の動作になります)。
  * **`:UEP open_file [Path]`**:
      * 現在のカーソル位置の行からインクルードパスを自動で抽出するか、`[Path]`で指定されたパスに基づいて、プロジェクトキャッシュ内からファイルを検索して開きます。
      * **インテリジェントな階層的検索**を実行します（現在のファイルディレクトリ、現在のモジュールのPublic/Privateフォルダ、依存モジュールなど）
  * **`:UEP add_include[!] [ClassName]`**:
      * C++クラスの正しい`#include`ディレクティブを検索し、挿入します。
      * `!`なし: `[ClassName]`引数が指定されていればそれを使用し、なければカーソル下の単語を使用します。
      * `!`あり: 引数やカーソル下の単語を無視し、常にプロジェクト全体のクラスを選択するためのピッカーUIを開きます。
      * **インテリジェントな挿入**: ヘッダーファイル(`.h`)では`.generated.h`の行の前に、ソースファイル(`.cpp`)では最後の`#include`文の後に、ディレクティブを挿入します。
  * **`:UEP find_derived[!] [ClassName]`**: 指定した基底クラスを継承する全てのクラスを検索します。
      * `!`なし: `[ClassName]`引数が指定されていればそれを使用し、なければカーソル下の単語を使用します。
      * `!`あり: 引数を無視し、常にプロジェクト全体のクラスから基底クラスを選択するためのピッカーUIを開きます。
  * **`:UEP find_parents[!] [ClassName]`**: 指定したクラスの継承チェーンを表示します。
      * `!`なし: `[ClassName]`引数が指定されていればそれを使用し、なければカーソル下の単語を使用します。
      * `!`あり: 引数を無視し、常にプロジェクト全体のクラスから起点となるクラスを選択するためのピッカーUIを開きます。
  * **`:UEP classes[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]`**: C++クラスの定義を選択し、ジャンプするためのピッカーを開きます。
      * フラグ: キャッシュの再生成とスコープのフィルタリングを制御します。
      * スコープ: デフォルトは\*\*`runtime`\*\*です。
      * Deps: デフォルトは\*\*`--deep-deps`\*\*です。
  * **`:UEP structs[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]`**: C++構造体の定義を選択し、ジャンプするためのピッカーを開きます。
      * フラグ: キャッシュの再生成とスコープのフィルタリングを制御します。
      * スコープ: デフォルトは\*\*`runtime`\*\*です。
      * Deps: デフォルトは\*\*`--deep-deps`\*\*です。
  * **`:UEP enums[!] [Game|Engine|Runtime|Editor|Full] [--no-deps|--shallow-deps|--deep-deps]`**: C++のEnum（列挙型）の定義を選択し、ジャンプするためのピッカーを開きます。
      * フラグ: キャッシュの再生成とスコープのフィルタリングを制御します。
      * スコープ: デフォルトは\*\*`runtime`\*\*です。
      * Deps: デフォルトは\*\*`--deep-deps`\*\*です。
  * **`:UEP purge [ComponentName]`**:
      * 指定されたGame、Engine、またはPluginコンポーネントの**ファイルキャッシュ** (`*.files.json`) のみを削除します。
      * プロジェクトの依存関係構造を再解析することなく、ファイルのスキャンを強制的に再実行したい場合に便利です。
  * **`:UEP cleanup`**:
      * **危険**: 現在のプロジェクトに関連する**全て**の構造キャッシュ (`*.project.json`) および**全て**のファイルキャッシュ (`*.files.json`) を永久に削除します（プラグインやリンクされたエンジンも含む）。
      * このコマンドはプログレスバーを表示しながら非同期で実行され、実行にはユーザーの確認が必要です。
      * 実行後、プロジェクトの構造をゼロから再構築するために、**必ず** `:UEP refresh Full` を実行してください。（引数なしの `:UEP refresh` は "Full" スコープにフォールバックします）
  * **`:UEP goto_definition[!] [ClassName]`**: 先行宣言をスキップして、クラスの実際の定義ファイルにジャンプします。
      * `!`なし: `[ClassName]`引数が指定されていればそれを使用し、なければカーソル下の単語を使用します。現在のモジュールの依存関係（現在のコンポーネント -\> 浅い依存 -\> 深い依存）に基づいて**インテリジェントな階層的検索**を実行し、見つからなければLSPにフォールバックします。
      * `!`あり: 引数やカーソル下の単語を無視し、常にプロジェクト全体のクラスを選択するためのピッカーUIを開きます。
  * **`:UEP system_open[!] [Path]`**:
      * 現在のバッファのファイルをシステムのファイルエクスプローラー（Windows Explorer, macOS Finder, xdg-openなど）で開き、ファイルを選択状態にします。
      * `!`なし:
          * `[Path]`引数があれば、そのパスを開きます。
          * 引数がなく、現在のバッファがファイルであれば、現在のファイルを開きます。
          * 現在のバッファがない場合、全プロジェクトファイルを対象とするピッカーにフォールバックします。
      * `!`あり:
          * 引数や現在のバッファを無視し、**プロジェクトのファイルキャッシュ**からファイルを選択するためのピッカーUIを強制的に開きます。
  * **`:UEP goto_super_def`**:
      * 現在カーソルがある関数の、親クラスにおける定義（ヘッダーファイル）へジャンプします。
      * キャッシュされたプロジェクトデータを使用して、継承チェーンをインテリジェントに解決します。
  * **`:UEP goto_super_impl`**:
      * 親クラスにおける関数の実装（ソースファイル）へジャンプします。
      * ソースファイルが見つからない場合は、ヘッダー定義へフォールバックします。
  * **`:UEP implement_virtual [ClassName]`**:
      * 親クラスの階層からオーバーライド可能な仮想関数をリストアップします。
      * 関数を選択すると、ヘッダーファイルに宣言を自動挿入し、実装スタブをクリップボードにコピーします。
      * ヘッダーファイル内で実行する必要があります。
  * **`:UEP find_module[!]`**:
      * プロジェクト全体のクラス、構造体、Enumを選択するためのピッカーUIを開きます。
      * 項目を選択すると、そのシンボルが所属しているモジュール名（例：`"Core"`, `"UMG"`）をダブルクォーテーション付きでシステムクリップボードにコピーします。
      * `Build.cs` の `PublicDependencyModuleNames.AddRange` などに依存関係を追加する際に非常に便利です。
      * `!` を付けると、キャッシュを強制的に更新してからピッカーを開きます。
  * **`:UEP build_cs[!]`**:
      * `!`なし: 現在編集中のファイルが属するモジュールの `Build.cs` を即座に開きます。モジュールが特定できない場合はピッカーを表示します。
      * `!`あり: プロジェクト内の全ての `Build.cs` をリストアップし、選択して開きます。
  * **`:UEP target_cs[!]`**:
      * `!`なし: 現在のプロジェクトに含まれる `Target.cs` をリストアップし、選択して開きます。ターゲットが1つしかない場合は即座に開きます。
      * `!`あり: エンジン側の `Target.cs` も含めた全てのターゲットをリストアップし、選択して開きます。
  * **`:UEP web_doc` / `:UEP web_doc!`**:
      * ブラウザでUnreal Engineの公式ドキュメントを開きます。
      * `!` なし: カーソル下の単語を検索します。
      * `!` あり: プロジェクト内のクラス一覧から選択して開きます。
      * **注釈 (Experimental)**: ドキュメントへの直リンクを生成するロジック（特にプラグイン周り）は現在ベータ版であり、完全ではありません。URLの推測に失敗した場合は、自動的にサイト内検索へフォールバックします。

## 🤖 API & 自動化 (Automation Examples)

`UEP.api`モジュールを使用して、他のNeovim設定と連携させることができます。

  * **`uep_api.open_file({opts})`**

      * インテリジェントな階層検索を使ってインクルードファイルを開きます。
      * `opts`テーブル:
          * `path` (string, optional): 検索対象のインクルードパス。省略した場合、現在の行から抽出されます。

  * **`uep_api.add_include({opts})`**

      * プログラムで`#include`ディレクティブを検索・挿入します。
      * `opts`テーブル:
          * `has_bang` (boolean, optional): `true`でピッカーUIを強制的に開きます。
          * `class_name` (string, optional): インクルードしたいクラス名。

### キーマップ作成例

日常的なタスクを素早く実行するためのキーマップを作成します。

#### インクルードファイルを開く (Open File)

標準の`gf`コマンドをUEPのインテリジェントなファイル検索で強化します。

```lua
-- init.lua や keymaps.lua などに記述
vim.keymap.set('n', 'gf', require('UEP.api').open_file, { noremap = true, silent = true, desc = "UEP: インクルードファイルを開く" })
```

#### インクルードを追加 (Add Include)

カーソル下のクラスに対する\#includeディレクティブを素早く追加します。

```lua
-- init.lua や keymaps.lua などに記述
vim.keymap.set('n', '<leader>ai', require('UEP.api').add_include, { noremap = true, silent = true, desc = "UEP: #includeディレクティブを追加" })
```

#### ファイル検索

現在のプロジェクトのファイルを素早く検索するためのキーマップを作成します。

```lua
-- init.lua や keymaps.lua などに記述
vim.keymap.set('n', '<leader>pf', function()
  -- APIはシンプルでクリーンです
  require('UEP.api').files({})
end, { desc = "UEP: プロジェクトファイル検索" })
```

#### 定義へジャンプ (UEP)

LSPのデフォルトジャンプを補完する、UEPのインテリジェントな定義ジャンプを使用します。

```lua
-- init.lua や keymaps.lua などに記述
-- 標準の 'gd' はLSPに使用
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { desc = "LSP 定義へジャンプ" })
-- <leader><C-]> をUEPの強化版ジャンプ（カーソル下の単語）に使用
vim.keymap.set('n', '<leader><C-]>', function() require('UEP.api').goto_definition({ has_bang = false }) end, { noremap = true, silent = true, desc = "UEP: 定義へジャンプ (カーソル)" })
-- オプション: <leader>gD をUEPのピッカー経由ジャンプに使用
vim.keymap.set('n', '<leader>gD', function() require('UEP.api').goto_definition({ has_bang = true }) end, { noremap = true, silent = true, desc = "UEP: 定義へジャンプ (ピッカー)" })

```

### Neo-treeとの連携

Neo-treeでキーマップを追加し、選択したディレクトリが属するプロジェクトを対象にUEPの論理ツリーを開きます。

```lua
-- Neo-treeのセットアップ例
opts = {
  filesystem = {
    window = {
      mappings = {
        ["<leader>pt"] = function(state)
          -- 現在選択されているノードのディレクトリを取得
          local node = state.tree:get_node()
          local path = node:get_id()
          if node.type ~= "directory" then
            path = require("vim.fs").dirname(path)
          end

          -- APIを呼ぶ前にCWDをプロジェクト内に設定
          vim.api.nvim_set_current_dir(path)
          require("UEP.api").tree({})
        end,
      },
    },
  },
}
```

## その他

Unreal Engine 関連プラグイン:

  * [UEP.nvim](https://github.com/taku25/UEP.nvim)
      * urpojectを解析してファイルナビゲートなどを簡単に行えるようになります
  * [UEA.nvim](https://www.google.com/search?q=https://github.com/taku25/UEA.nvim)
      * C++クラスがどのBlueprintアセットから使用されているかを検索します
  * [UBT.nvim](https://github.com/taku25/UBT.nvim)
      * BuildやGenerateClangDataBaseなどを非同期でNeovim上から使えるようになります
  * [UCM.nvim](https://github.com/taku25/UCM.nvim)
      * クラスの追加や削除がNeovim上からできるようになります。
  * [ULG.nvim](https://github.com/taku25/ULG.nvim)
      * UEのログやliveCoding,stat fpsなどnvim上からできるようになります
  * [USH.nvim](https://github.com/taku25/USH.nvim)
      * ushellをnvimから対話的に操作できるようになります
  * [neo-tree-unl](https://github.com/taku25/neo-tree-unl.nvim)
      * IDEのようなプロジェクトエクスプローラーを表示できます。
  * [tree-sitter for Unreal Engine](https://github.com/taku25/tree-sitter-unreal-cpp)
      * UCLASSなどを含めてtree-sitterの構文木を使ってハイライトができます。

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
