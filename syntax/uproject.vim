" UEP.nvim/syntax/uproject.vim

" 1. すでに読み込み済みの場合は何もしない (定型文)
if exists("b:current_syntax")
  finish
endif

" 2. JSONのシンタックスを継承
"    これにより、まず全体がJSONとしてハイライトされます
runtime! syntax/json.vim

