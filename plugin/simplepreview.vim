vim9script
if exists('g:loaded_simplepreview')
  finish
endif
g:loaded_simplepreview = true
command! -nargs=* SimplePreviewStart simplepreview#Start([<f-args>])
command! SimplePreviewLogs simplepreview#Logs()
command! -nargs=? SimplePreviewOpen simplepreview#Open(<q-args>)
command! SimplePreviewStatus echo simplepreview#Status()
command! SimplePreviewRestart simplepreview#Restart()
command! SimplePreviewStop simplepreview#Stop()
augroup SimplePreview
  autocmd!
  autocmd VimLeavePre * simplepreview#Stop()
augroup END
