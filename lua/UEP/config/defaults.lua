local M = {
  
  -- UEPプラグイン固有の設定テーブルを追加
  uep = {
    -- refreshコマンド実行時に自動で設定をリロードするかどうか
    auto_reload_config_on_refresh = true,
  },
  cache = { dirname = "UEP" },

  files_extensions = {
    "cpp", "h", "hpp", "inl", "ini", "cs",
  },

  logging = {
    level = "info",
    echo = { level = "warn" },
    notify = { level = "error", prefix = "[UEP]" },
    file = { enable = true, max_kb = 512, rotate = 3, filename = "uep.log" },
    perf = { enabled = false, patterns = { "^refresh" }, level = "trace" },
  },

  ui = {

    picker = {
      mode = "fzf-lua",
      prefer = { "telescope", "fzf-lua", "native", "dummy" },
    },

    progress = {
      mode = "auto",
      enable = true,
      prefer = { "fidget", "generic_status", "window", "notify", "dummy" },
      allow_regression = false,
      weights = {
        -- UEP.nvimが使うステージ名に合わせて重みを設定
        scanning      = 0.05, -- fd でのファイル検索
        parse_modules = 0.40, -- Build.cs の解析
        resolve_deps  = 0.50, -- 依存関係の解決
        save_cache    = 0.05, -- キャッシュの保存
      },
    },
  },
}

return M
