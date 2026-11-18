vim9script
delete('/tmp/simplepreview-vim-errors')
const Repo = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(Repo)
runtime plugin/simplepreview.vim
const Temp = tempname() .. " project ' space"
mkdir(Temp .. '/src/nested', 'p')
writefile(['{}'], Temp .. '/package.json')
writefile(['{}'], Temp .. '/src/nested/package.json')
const RootLink = Temp .. '-root-link'
const SubdirLink = Temp .. '-subdir-link'
const FileLink = Temp .. '-file-link'
const DanglingLink = Temp .. '-dangling-link'
for [target, link] in [[Temp, RootLink], [Temp .. '/src', SubdirLink],
    [Temp .. '/package.json', FileLink], [Temp .. '/missing', DanglingLink]]
  system('ln -s ' .. shellescape(target) .. ' ' .. shellescape(link))
  assert_equal(0, v:shell_error)
endfor


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
  Throws('SimplePreviewRestart', 'SimplePreview: no previous command')
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
  # Explicit root typos must never select and execute an ancestor project.
  for invalid_root in [Temp .. '/missing-root', Temp .. '/src',
      Temp .. '/src/new.tsx', Temp .. '/package.json', 'scp://host/project',
      SubdirLink, FileLink, DanglingLink]
    g:preview_test_root = invalid_root
    Throws("simplepreview#Start(['python3', '-c', 'print(123)'], g:preview_test_root)", 'SimplePreview: explicit project root')
    assert_equal('idle', simplepreview#Status().state)
    g:simplepreview_root = invalid_root
    Throws("simplepreview#Start(['python3', '-c', 'print(123)'])", 'SimplePreview: explicit project root')
    assert_equal('idle', simplepreview#Status().state)
  endfor
  unlet g:preview_test_root
  g:simplepreview_root = Temp
  # No auto start when sourcing, entering a TSX buffer or writing it.
  execute 'edit ' .. fnameescape(Temp .. '/src/index.tsx')
  setfiletype typescriptreact
  write
  assert_equal('idle', simplepreview#Status().state)
  # With no override, discovery still walks up from the current local file.
  unlet g:simplepreview_root
  simplepreview#Start(['python3', '-c', 'print("auto-root")'])
  WaitFor('exited')
  assert_equal(Temp, simplepreview#Status().root)
  # An explicit symlink to a valid project resolves to its canonical directory.
  simplepreview#Start(['python3', '-c', 'print("symlink-root")'], RootLink .. '/')
  WaitFor('exited')
  assert_equal(Temp, simplepreview#Status().root)
  # Resolve symlinks before '..': the real parent differs from the alias parent.
  simplepreview#Start(['python3', '-c', 'print("symlink-parent")'], SubdirLink .. '/..')
  WaitFor('exited')
  assert_equal(Temp, simplepreview#Status().root)
  var prior_cwd = getcwd()
  execute 'lcd ' .. fnameescape(Temp)
  simplepreview#Start(['python3', '-c', 'print("relative-root")'], '.')
  WaitFor('exited')
  assert_equal(Temp, simplepreview#Status().root)
  assert_equal(Temp, getcwd())
  execute 'lcd ' .. fnameescape(prior_cwd)
  g:simplepreview_root = Temp
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

  # Restart retains an explicit dev:web-like argv and root; no project script.
  simplepreview#Start(['python3', Repo .. '/tests/restart_fixture.py', 'dev:web'], Temp)
  for _ in range(100)
    if !empty(simplepreview#Status().url)
      break
    endif
    sleep 20m
  endfor
  assert_equal('http://localhost:5173/', simplepreview#Status().url)
  var original_command = simplepreview#Status().command
  g:simplepreview_command = ['not-the-original-command']
  g:simplepreview_root = Temp .. '/src/nested'
  SimplePreviewRestart
  SimplePreviewRestart
  assert_true(simplepreview#Status().restart_pending)
  for _ in range(150)
    if len(readfile(Temp .. '/restart-runs.jsonl')) == 2 && !empty(simplepreview#Status().url)
      break
    endif
    sleep 20m
  endfor
  assert_equal('running', simplepreview#Status().state)
  assert_false(simplepreview#Status().restart_pending)
  assert_equal(original_command, simplepreview#Status().command)
  var runs = readfile(Temp .. '/restart-runs.jsonl')
  assert_equal(2, len(runs))
  for run in runs
    var record = json_decode(run)
    assert_equal(Temp, record.cwd)
    assert_equal(['dev:web'], record.args)
  endfor
  # A missing marker must not silently retarget the restart to an ancestor.
  rename(Temp .. '/package.json', Temp .. '/package.saved')
  Throws('SimplePreviewRestart', 'SimplePreview: original project root')
  assert_equal('running', simplepreview#Status().state)
  rename(Temp .. '/package.saved', Temp .. '/package.json')
  SimplePreviewRestart
  SimplePreviewStop
  WaitFor('exited')
  assert_false(simplepreview#Status().restart_pending)
  assert_equal(2, len(readfile(Temp .. '/restart-runs.jsonl')))
  SimplePreviewRestart
  for _ in range(100)
    if len(readfile(Temp .. '/restart-runs.jsonl')) == 3
      break
    endif
    sleep 20m
  endfor
  assert_equal(3, len(readfile(Temp .. '/restart-runs.jsonl')))
  SimplePreviewRestart
  # The marker can vanish after queueing too; failure must not spawn or loop.
  rename(Temp .. '/package.json', Temp .. '/package.saved')
  WaitFor('failed')
  sleep 150m  # Late output/close callbacks must not replace the failure.
  assert_false(simplepreview#Status().restart_pending)
  assert_equal(3, len(readfile(Temp .. '/restart-runs.jsonl')))
  assert_match('original project root', simplepreview#Status().last_line)
  rename(Temp .. '/package.saved', Temp .. '/package.json')
  SimplePreviewStop
  # A queued restart also fails closed if its original executable disappears.
  var executable_copy = Temp .. '/tools/restart-server'
  writefile(['#!/usr/bin/env python3'] + readfile(Repo .. '/tests/restart_fixture.py'), executable_copy)
  setfperm(executable_copy, 'rwx------')
  simplepreview#Start([executable_copy, 'custom:web'], Temp)
  for _ in range(100)
    if !empty(simplepreview#Status().url)
      break
    endif
    sleep 20m
  endfor
  assert_equal(4, len(readfile(Temp .. '/restart-runs.jsonl')))
  SimplePreviewRestart
  delete(executable_copy)
  WaitFor('failed')
  sleep 150m  # Late output/close callbacks must not replace the failure.
  assert_false(simplepreview#Status().restart_pending)
  assert_equal(4, len(readfile(Temp .. '/restart-runs.jsonl')))
  assert_match('executable not found', simplepreview#Status().last_line)
  SimplePreviewStop
  unlet g:simplepreview_command g:simplepreview_root

  # Opening the current managed Canvas can start its own preview without a package.json.
  var old_home = $HOME
  $HOME = Temp .. '/canvas-home'
  var canvas_dir = $HOME .. '/.cursor/projects/workspace/canvases'
  mkdir(canvas_dir, 'p')
  var canvas_file = canvas_dir .. "/roadmap ' space.canvas.tsx"
  writefile(['export default function Roadmap() { return <h1>Roadmap</h1> }'], canvas_file)
  g:simplepreview_canvas_runtime = Temp .. '/runtime.mjs'
  g:simplepreview_canvas_typescript = Temp .. '/typescript.js'
  writefile([], g:simplepreview_canvas_runtime)
  writefile([], g:simplepreview_canvas_typescript)
  writefile(['#!/bin/sh', 'printf "%s\n" "$@" > "$SP_CANVAS_ARGS"',
    'sleep 0.1', 'printf "http://127.0.0.1:32123/\n"', 'sleep 30'], Temp .. '/tools/node')
  setfperm(Temp .. '/tools/node', 'rwx------')
  $SP_CANVAS_ARGS = Temp .. '/canvas-args.txt'
  delete($SP_OPEN_LOG)
  execute 'edit ' .. fnameescape(canvas_file)
  assert_equal('failed', simplepreview#Status().state)
  assert_false(filereadable($SP_CANVAS_ARGS))
  if !has('macunix')
    SimplePreviewOpen
    SimplePreviewOpen
    for _ in range(100)
      if filereadable($SP_OPEN_LOG)
        break
      endif
      sleep 20m
    endfor
    assert_equal(['http://127.0.0.1:32123/'], readfile($SP_OPEN_LOG))
    assert_equal(canvas_dir, simplepreview#Status().root)
    assert_equal([Repo .. '/bin/preview-canvas.cjs', canvas_file,
      g:simplepreview_canvas_runtime, g:simplepreview_canvas_typescript],
      readfile($SP_CANVAS_ARGS))
    assert_false(filereadable(canvas_dir .. '/package.json'))
    SimplePreviewStop
    WaitFor('exited')
  endif
  SimplePreviewStart
  assert_equal('running', simplepreview#Status().state)
  assert_equal(canvas_dir, simplepreview#Status().root)
  SimplePreviewStop
  WaitFor('exited')
  $HOME = old_home
catch
  assert_report(v:exception .. ' at ' .. v:throwpoint)
finally
  simplepreview#Stop()
endtry
if !empty(v:errors)
  writefile(v:errors, '/tmp/simplepreview-vim-errors')
  cquit
endif
for link in [RootLink, SubdirLink, FileLink, DanglingLink]
  delete(link)
endfor
delete(Temp, 'rf')
qa!
