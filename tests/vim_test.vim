vim9script
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
