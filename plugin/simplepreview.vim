vim9script
if exists('g:loaded_simplepreview')
  finish
endif
g:loaded_simplepreview = true
command! -nargs=* SimplePreviewStart simplepreview#Start([<f-args>])
command! SimplePreviewOpen simplepreview#Open()
command! SimplePreviewStatus echo simplepreview#Status()
command! SimplePreviewStop simplepreview#Stop()
augroup SimplePreview
  autocmd!
  autocmd VimLeavePre * simplepreview#Stop()
augroup END
