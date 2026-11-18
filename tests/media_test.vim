vim9script
const Repo = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(Repo)
runtime plugin/simplepreview.vim
const Temp = tempname() .. " media ' 中文"
mkdir(Temp, 'p')
const OriginalPath = $PATH
$PATH = Temp .. ':' .. $PATH
$SP_MEDIA_ARGS = Temp .. '/args'
writefile(['#!/bin/sh', 'printf "%s\n" "$@" > "$SP_MEDIA_ARGS"', 'sleep 30'], Temp .. '/ffplay')
setfperm(Temp .. '/ffplay', 'rwx------')

def Throws(cmd: string, expected: string)
  try
    execute cmd
    assert_report('Expected failure: ' .. cmd)
  catch
    assert_match(expected, v:exception)
  endtry
enddef

def WaitExit()
  for _ in range(150)
    if index(['exited', 'failed'], simplepreview_media#Status().state) >= 0
      return
    endif
    sleep 20m
  endfor
  assert_report('Media stop timed out')
enddef

try
  assert_equal('idle', simplepreview_media#Status().state)
  assert_false(filereadable($SP_MEDIA_ARGS))
  var file = Temp .. "/-photo ' ; $(touch pwned) 中文.png"
  writefile(['stub image'], file)
  execute 'SimplePreviewImage ' .. file
  for _ in range(100)
    if filereadable($SP_MEDIA_ARGS)
      break
    endif
    sleep 20m
  endfor
  assert_equal('running', simplepreview_media#Status().state, string(simplepreview_media#Status()))
  var args = filereadable($SP_MEDIA_ARGS) ? readfile($SP_MEDIA_ARGS) : []
  assert_equal(['-i', file], args[-2 :])
  assert_equal('file', args[index(args, '-protocol_whitelist') + 1])
  assert_equal('png_pipe,jpeg_pipe,webp_pipe,bmp_pipe', args[index(args, '-format_whitelist') + 1])
  assert_equal('running', simplepreview_media#Status().state)
  assert_equal('idle', simplepreview#Status().state)
  Throws('SimplePreviewImage', 'stop the current media')
  SimplePreviewMediaStop
  SimplePreviewMediaStop
  WaitExit()
  for name in ['https://example.com/a.png', Temp, Temp .. '/missing.png']
    Throws('call simplepreview_media#Preview("image", ' .. string(name) .. ')', 'SimplePreview:')
  endfor
  system('mkfifo ' .. shellescape(Temp .. '/pipe.png'))
  Throws('call simplepreview_media#Preview("image", ' .. string(Temp .. '/pipe.png') .. ')', 'regular file')
  system('ln -s ' .. shellescape(file) .. ' ' .. shellescape(Temp .. '/link.png'))
  simplepreview_media#Preview('image', Temp .. '/link.png')
  assert_equal(file, simplepreview_media#Status().path)
  SimplePreviewMediaStop
  WaitExit()
  for ext in ['m3u', 'svg', 'desktop', 'txt']
    var rejected = Temp .. '/bad.' .. ext
    writefile(['bad'], rejected)
    Throws('call simplepreview_media#Preview("image", ' .. string(rejected) .. ')', 'unsupported media')
  endfor
  writefile(['stub video'], Temp .. '/clip.mp4')
  execute 'edit ' .. fnameescape(Temp .. '/clip.mp4')
  SimplePreviewVideo
  assert_equal(Temp .. '/clip.mp4', simplepreview_media#Status().path)
  SimplePreviewMediaStop
  WaitExit()
  $PATH = Temp
  Throws('SimplePreviewVideo', 'install dependencies yourself')
catch
  assert_report(v:exception .. ' at ' .. v:throwpoint)
finally
  $PATH = OriginalPath
  simplepreview_media#Stop()
endtry
if !empty(v:errors)
  writefile(v:errors, '/tmp/simplepreview-media-errors')
  cquit
endif
delete(Temp, 'rf')
qa!
