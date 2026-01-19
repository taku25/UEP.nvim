local M = {
  
  -- UEPプラグイン固有の設定テーブルを追加
    -- refreshコマンド実行時に自動で設定をリロードするかどうか
    auto_reload_config_on_refresh = true,
  
  server = {
    enable = true,
    name = "UEP_nvim",
  },

  ide = {
    -- Command template to open file in IDE.
    -- Placeholders: {file}, {line}
    -- Examples:
    -- Rider: "rider --line {line} {file}" 
    -- VS Code: "code -g {file}:{line}"
    -- Visual Studio: "devenv /edit {file} /command \"Edit.GoTo {line}\"" (Adjust path to devenv if needed)
    open_command = "rider --line {line} \"{file}\"", 
  },

  shader = {
    -- 自動解決でカバーできないパスを手動で追加
    -- 例: { ["/MyCustom/"] = "Source/MyGame/Shaders/" }
    extra_mappings = {},
  },
  config_explorer = {
    -- 強制的に表示対象とする主要プラットフォームのリスト
    major_platforms = { 
      "Windows", "Mac", "Linux", "Android", "IOS", "TVOS", "Apple", "Unix" 
    },
  },
  cache = { dirname = "UEP" },
  
  include_extensions = { "uproject", "cpp", "h", "hpp", "inl", "ini", "cs", "usf", "ush" },
  include_directory = { "Source", "Plugins", "Config", "Shaders", "Programs", "Platforms" },
  excludes_directory  = {  "Intermediate", "Binaries", "Saved", ".git", ".vs", "Templates" },

  engine_path = nil,

  files_extensions = {
    "cpp", "h", "hpp", "inl", "ini", "cs", "usf", "ush",
  },

  logging = {
    level = "info",
    echo = { level = "warn" },
    notify = { level = "error", prefix = "[UEP]" },
    file = { level = "info", enable = true, max_kb = 512, rotate = 3, filename = "uep.log" },
    perf = { enabled = false, patterns = { "^refresh" }, level = "trace" },
  },

  ui = {

    picker = {
      mode = "auto",
      prefer = { "telescope", "fzf-lua", "snacks", "native", "dummy" },
    },
    grep_picker = {
      mode = "auto",
      prefer = { "telescope", "fzf-lua", "snacks", }
    },
    dynamic_picker = {
      mode = "auto",
      prefer = { "telescope", "fzf-lua", "snacks", }
    },

    progress = {
      mode = "auto",
      enable = true,
      prefer = { "fidget", "generic_status", "window", "notify", "dummy" },
      allow_regression = false,
      weights = {
        -- UEP.nvimが使うステージ名に合わせて重みを設定
        -- scanning      = 0.05, -- fd でのファイル検索
        analyze_components = 0.4,
        -- parse_modules = 0.30, -- Build.cs の解析
        -- resolve_deps  = 0.30, -- 依存関係の解決
        -- create_file_cache = 0.15,
        -- header_analysis = 0.3,
        -- header_analysis_detail = 0.15,
        save_cache    = 0.05, -- キャッシュの保存
      },
    },
  },
}

return M
