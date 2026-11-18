vim9script
delete('/tmp/simplepreview-vim-errors')
const Repo = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(Repo)
runtime plugin/simplepreview.vim
const Temp = tempname() .. " project ' space"
mkdir(Temp .. '/src/nested', 'p')
writefile(['{}'], Temp .. '/package.json')
writefile(['{}'], Temp .. '/src/nested/package.json')

def Throws(cmd: string, expected: string)
  try
    execute cmd
    assert_report('Expected failure: ' .. cmd)
  catch
    assert_match(expected, v:exception)
  endtry
enddef

def WaitFor(state: string)
  for _ in range(100)
    if simplepreview#Status().state == state
      return
    endif
    sleep 30m
  endfor
  assert_report('Timed out waiting for ' .. state .. ': ' .. string(simplepreview#Status()))
enddef

try
  assert_equal('idle', simplepreview#Status().state)
  for token in ['http://localhost:5173/', 'https://127.0.0.1:443/', 'http://[::1]:8000/']
    assert_equal(token, simplepreview#LocalURL(token))
  endfor
  assert_equal('http://localhost:1/', simplepreview#LocalURL('http://localhost:1'))
  for token in ['http://evil.com:80/', 'http://localhost.evil.com:80/',
      'http://127.0.0.1:80@evil.com/', 'http://localhost:80\\@evil.com',
      'http://localhost:0/', 'http://localhost:65536/', 'http://localhost:999999/',
      'http://0.0.0.0:80/', 'http://127.1:80/', 'http://2130706433:80/',
      'file:///tmp/a', '--help', 'http://[::1].evil:80/',
      'http://localhost:80/path', 'http://localhost:80/?q=x',
      "http://localhost:80/\n", 'http://localhost:80/#x']
    assert_equal('', simplepreview#LocalURL(token), token)
  endfor
  for page in ['/', '/web-index.html', '/nested/app-v2_1.html', '/~preview/']
    assert_equal('http://localhost:5173' .. page, simplepreview#PageURL('http://localhost:5173/', page))
  endfor
  for page in ['', 'web-index.html', '//evil.example/', '/a//b', '/../x', '/a/./b',
      'https://evil.example/', '/x?redirect=https://evil.example', '/x#fragment',
      '/%2f%2fevil.example', '/%2e%2e/x', '/x\y', "/x\ny", '/x y', '/@evil', repeat('/a', 1025)]
    assert_equal('', simplepreview#PageURL('http://localhost:5173/', page), page)
  endfor
  assert_equal('', simplepreview#PageURL('http://evil.example:80/', '/web-index.html'))
  assert_equal(Temp, simplepreview#ProjectRoot(Temp .. '/src/index.tsx'))
  assert_equal(Temp .. '/src/nested', simplepreview#ProjectRoot(Temp .. '/src/nested/index.tsx'))
  assert_equal('', simplepreview#ProjectRoot('scp://host/project'))
  assert_equal('', simplepreview#ProjectRoot('/definitely/nonexistent/project'))
  simplepreview#Stop()
  Throws('SimplePreviewOpen', 'SimplePreview: no running')
  g:simplepreview_root = Temp
  Throws("simplepreview#Start(['definitely-missing-executable'])", 'SimplePreview: executable not found')
  # No auto start when sourcing, entering a TSX buffer or writing it.
  execute 'edit ' .. fnameescape(Temp .. '/src/index.tsx')
  setfiletype typescriptreact
  write
  assert_equal('idle', simplepreview#Status().state)
  # Browser stub records argv, so no real browser is launched by tests.
  mkdir(Temp .. '/tools')
  writefile(['#!/bin/sh', 'printf "%s\n" "$@" > "$SP_OPEN_LOG"'], Temp .. '/tools/xdg-open')
  setfperm(Temp .. '/tools/xdg-open', 'rwx------')
  $PATH = Temp .. '/tools:' .. $PATH
  $SP_OPEN_LOG = Temp .. '/open.txt'
  simplepreview#Start(['python3', Repo .. '/tests/fixture.py', 'literal; touch NEVER', 'two words'], Temp)
  for _ in range(100)
    if !empty(simplepreview#Status().url)
      break
    endif
    sleep 20m
  endfor
  assert_equal('http://localhost:5173/', simplepreview#Status().url)
  assert_equal(Temp, simplepreview#Status().root)
  assert_match('literal; touch NEVER', readfile(Temp .. '/observed.txt')[0])
  assert_false(filereadable(Temp .. '/NEVER'))
  assert_false(filereadable($SP_OPEN_LOG))
  Throws('SimplePreviewStart', 'SimplePreview: stop the current')
  if !has('macunix')
    SimplePreviewOpen
    for _ in range(100)
      if filereadable($SP_OPEN_LOG)
        break
      endif
      sleep 10m
    endfor
    assert_equal(['http://localhost:5173/'], readfile($SP_OPEN_LOG))
    SimplePreviewOpen /web-index.html
    for _ in range(100)
      if readfile($SP_OPEN_LOG) == ['http://localhost:5173/web-index.html']
        break
      endif
      sleep 10m
    endfor
    assert_equal(['http://localhost:5173/web-index.html'], readfile($SP_OPEN_LOG))
    g:simplepreview_path = '/nested/app.html'
    SimplePreviewOpen
    for _ in range(100)
      if readfile($SP_OPEN_LOG) == ['http://localhost:5173/nested/app.html']
        break
      endif
      sleep 10m
    endfor
    assert_equal(['http://localhost:5173/nested/app.html'], readfile($SP_OPEN_LOG))
    SimplePreviewOpen /
    for _ in range(100)
      if readfile($SP_OPEN_LOG) == ['http://localhost:5173/']
        break
      endif
      sleep 10m
    endfor
    assert_equal(['http://localhost:5173/'], readfile($SP_OPEN_LOG))
    Throws('SimplePreviewOpen //evil.example/', 'SimplePreview: page must')
    g:simplepreview_path = 'https://evil.example/'
    Throws('SimplePreviewOpen', 'SimplePreview: page must')
    assert_equal(['http://localhost:5173/'], readfile($SP_OPEN_LOG))
    unlet g:simplepreview_path

  endif
  SimplePreviewStop
  SimplePreviewStop
  WaitFor('exited')
  Throws('SimplePreviewOpen', 'SimplePreview: no running')
  simplepreview#Start(['python3', '-c', 'print("done"); exit(7)'], Temp)
  WaitFor('exited')
  assert_equal(7, simplepreview#Status().exit_code)
  assert_equal('', simplepreview#Status().url)
  assert_equal('done', simplepreview#Status().last_line)
  # Relative executables resolve under project, never Vim's unrelated cwd.
  writefile(['#!/bin/sh', 'printf relative-ok'], Temp .. '/tools/server')
  setfperm(Temp .. '/tools/server', 'rwx------')
  simplepreview#Start(['./tools/server'], Temp)
  WaitFor('exited')
  assert_equal('relative-ok', simplepreview#Status().last_line)
  assert_equal(0, simplepreview#Status().exit_code)
  # A readable diagnostic tail retains earlier build errors, not only last_line.
  simplepreview#Start(['python3', '-c', 'print("ERROR: missing module"); print("build failed"); exit(2)'], Temp)
  WaitFor('exited')
  SimplePreviewLogs
  var logbuf = bufnr()
  assert_equal(['ERROR: missing module', 'build failed'], getline(1, '$'))
  assert_equal('nofile', &buftype)
  assert_false(&modifiable)
  assert_false(&modeline)
  assert_false(&swapfile)
  assert_true(&readonly)
  assert_false(&modified)
  assert_equal(-1, &undolevels)
  assert_equal([], undotree().entries)
  var windows = winnr('$')
  SimplePreviewLogs
  assert_equal(logbuf, bufnr())
  assert_equal(windows, winnr('$'))
  # Restart from the diagnostic window uses the owned session's project root.
  unlet g:simplepreview_root
  simplepreview#Start(['python3', '-c', 'print("fresh"); exit(0)'])
  assert_equal(['No output yet.'], getbufline(logbuf, 1, '$'))
  WaitFor('exited')
  assert_equal(['fresh'], getbufline(logbuf, 1, '$'))
  assert_equal([], undotree().entries)
  assert_equal(Temp, simplepreview#Status().root)
  simplepreview#Start(['python3', '-c', 'import sys; print("\x1b]8;;https://evil.example\x07label\x1b]8;;\x07"); print(chr(27)+"]0;hidden title"+chr(27)+chr(92)+"visible"); print("\x1b[31mred\x1b[0m"); print("中" * 600)'], Temp)
  WaitFor('exited')
  assert_equal('label', getbufline(logbuf, 1)[0])
  assert_equal('visible', getbufline(logbuf, 2)[0])
  assert_equal('red', getbufline(logbuf, 3)[0])
  assert_equal(repeat('中', 512), getbufline(logbuf, 4)[0])
  # Force multiple raw callbacks and a UTF-8 split across the old byte cap.
  simplepreview#Start(['python3', '-c', 'import sys,time; data=("中"*4000).encode(); sys.stdout.buffer.write(data[:9001]); sys.stdout.buffer.flush(); time.sleep(.1); sys.stdout.buffer.write(data[9001:]+b"\n"); sys.stdout.buffer.flush()'], Temp)
  WaitFor('exited')
  assert_equal(repeat('中', 512), getbufline(logbuf, 1)[0])
  simplepreview#Start(['python3', '-c', '[print("line-%d" % n) for n in range(250)]'], Temp)
  WaitFor('exited')
  assert_equal(200, len(getbufline(logbuf, 1, '$')))
  assert_equal('line-50', getbufline(logbuf, 1)[0])
  assert_equal('line-249', getbufline(logbuf, '$')[0])
  close
  assert_false(bufexists(logbuf))
  SimplePreviewLogs
  assert_equal(200, line('$'))
  close

catch
  assert_report(v:exception .. ' at ' .. v:throwpoint)
finally
  simplepreview#Stop()
endtry
if !empty(v:errors)
  writefile(v:errors, '/tmp/simplepreview-vim-errors')
  cquit
endif
delete(Temp, 'rf')
qa!
