local M = {
  
  -- UEPプラグイン固有の設定テーブルを追加
  uep = {
    -- refreshコマンド実行時に自動で設定をリロードするかどうか
    auto_reload_config_on_refresh = true,
  },
  cache = { dirname = "UEP" },
  
  include_extensions = { "uproject", "cpp", "h", "hpp", "inl", "ini", "cs", "usf", "ush" },
  include_directory = { "Source", "Plugins", "Config", "Shaders", "Programs", "Platforms" },
  excludes_directory  = {  "Intermediate", "Binaries", "Saved", ".git", ".vs", "Templates" },

  files_extensions = {
    "cpp", "h", "hpp", "inl", "ini", "cs",
  },

  logging = {
    level = "info",
    echo = { level = "warn" },
    notify = { level = "error", prefix = "[UEP]" },
    file = { level = "trace", enable = true, max_kb = 512, rotate = 3, filename = "uep.log" },
    perf = { enabled = false, patterns = { "^refresh" }, level = "trace" },
  },

  ui = {

    picker = {
      mode = "auto",
      prefer = { "telescope", "fzf-lua", "native", "dummy" },
    },
    grep_picker = {
      mode = "auto",
      prefer = { "telescope", "fzf-lua" }
    },
    dynamic_picker = {
      mode = "auto",
      prefer = { "telescope", "fzf-lua" }
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
