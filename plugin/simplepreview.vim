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
command! -nargs=? SimplePreviewImage simplepreview_media#Preview('image', <q-args>)
command! -nargs=? SimplePreviewVideo simplepreview_media#Preview('video', <q-args>)
command! SimplePreviewMediaStatus echo simplepreview_media#Status()
command! SimplePreviewMediaStop simplepreview_media#Stop()
augroup SimplePreview
  autocmd!
  autocmd VimLeavePre * simplepreview#Stop() | simplepreview_media#Stop()
augroup END
