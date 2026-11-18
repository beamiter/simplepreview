vim9script
const Bin = expand('<sfile>:p:h:h') .. '/bin/'
const Supervisor = Bin .. 'supervise.py'
var server: job
var phase = 'idle'
var root = ''
var command: list<string> = []
var url = ''
var pending = ''
var last_line = ''
var exit_code = -1
var generation = 0
var pending_restart: dict<any> = {}
var canvas = ''
var open_canvas_when_ready = false
var log_lines: list<string> = []
var log_buffer = -1
const LogLimit = 200
const LogLineChars = 512

# Exact loopback origins only: no credentials, path, DNS suffix or query.
export def LocalURL(token: string): string
  var m = matchlist(token, '^\(https\?\)://\(localhost\|127\.0\.0\.1\|\[::1\]\):\([0-9]\{1,5}\)/\?$')
  if empty(m) || str2nr(m[3]) < 1 || str2nr(m[3]) > 65535
    return ''
  endif
  return m[1] .. '://' .. m[2] .. ':' .. m[3] .. '/'
enddef

# Explicit page paths only. Never take a path, query or redirect from output.
export def PageURL(origin: string, path: string): string
  var local_origin = LocalURL(origin)
  if empty(local_origin) || strlen(path) > 2048
      || path !~# '^/[A-Za-z0-9._~/-]*$' || stridx(path, '//') >= 0
    return ''
  endif
  for segment in split(path, '/', true)
    if segment == '.' || segment == '..'
      return ''
    endif
  endfor
  return strpart(local_origin, 0, strlen(local_origin) - 1) .. path
enddef

export def ProjectRoot(start: string): string
  if start =~# '^\a\+://' || empty(start)
    return ''
  endif
  var dir = resolve(fnamemodify(start, ':p'))
  if !isdirectory(dir)
    dir = fnamemodify(dir, ':h')
  endif
  while isdirectory(dir)
    if filereadable(dir .. '/package.json')
      return dir == '/' ? dir : substitute(dir, '/$', '', '')
    endif
    var parent = fnamemodify(dir, ':h')
    if parent == dir
      break
    endif
    dir = parent
  endwhile
  return ''
enddef

def ExactProjectRoot(path: string): string
  if empty(path) || path =~# '^\a\+://' || !isdirectory(path)
    return ''
  endif
  var dir = resolve(fnamemodify(path, ':p'))
  dir = dir == '/' ? dir : substitute(dir, '/$', '', '')
  return filereadable(dir .. '/package.json') ? dir : ''
enddef

def CurrentCanvas(): string
  if &buftype != '' || bufname() =~# '^\a\+://' || expand('%:p') !~# '\.canvas\.tsx$'
    return ''
  endif
  var path = resolve(expand('%:p'))
  var projects = resolve(expand('~/.cursor/projects'))
  if stridx(path, projects .. '/') == 0
      && strpart(path, strlen(projects) + 1) =~# '^[^/]\+/canvases/[^/]\+\.canvas\.tsx$'
    return path
  endif
  return ''
enddef

def StartCanvas(path: string)
  if !filereadable(path)
    throw 'SimplePreview: save the Canvas file before previewing it'
  endif
  var runtime = get(g:, 'simplepreview_canvas_runtime', '')
  if empty(runtime) && executable('cursor')
    var install = fnamemodify(resolve(exepath('cursor')), ':h:h')
    for app in [install .. '/resources/app', install]
      var candidate = app .. '/extensions/cursor-agent-exec/dist/canvas-runtime/canvas-runtime.esm.js'
      if filereadable(candidate)
        runtime = candidate
        break
      endif
    endfor
  endif
  if !filereadable(runtime)
    throw 'SimplePreview: Cursor Canvas runtime not found; set g:simplepreview_canvas_runtime'
  endif
  var data_home = empty($XDG_DATA_HOME) ? expand('~/.local/share') : $XDG_DATA_HOME
  var compiler = get(g:, 'simplepreview_canvas_typescript',
    data_home .. '/simplecc/servers/typescript-language-server/node_modules/typescript/lib/typescript.js')
  if !filereadable(compiler)
    throw 'SimplePreview: TypeScript compiler not found; install it via SimpleCC or set g:simplepreview_canvas_typescript'
  endif
  Launch(fnamemodify(path, ':h'), ['node', Bin .. 'preview-canvas.cjs', path,
    fnamemodify(runtime, ':p'), fnamemodify(compiler, ':p')], path)
enddef

export def Status(): dict<any>
  return {state: phase, root: root, command: copy(command), url: url,
          exit_code: exit_code, last_line: last_line, restart_pending: !empty(pending_restart)}
enddef

def RefreshLogs()
  if log_buffer < 0 || !bufexists(log_buffer)
    return
  endif
  setbufvar(log_buffer, '&modifiable', 1)
  setbufline(log_buffer, 1, empty(log_lines) ? ['No output yet.'] : log_lines)
  var count = empty(log_lines) ? 1 : len(log_lines)
  deletebufline(log_buffer, count + 1, '$')
  setbufvar(log_buffer, '&modified', 0)
  setbufvar(log_buffer, '&modifiable', 0)
enddef

export def Logs()
  var windows = log_buffer < 0 ? [] : win_findbuf(log_buffer)
  if !empty(windows)
    win_gotoid(windows[0])
    return
  endif
  botright new
  resize 12
  log_buffer = bufnr()
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted nowrap nomodeline
  setlocal readonly undolevels=-1
  b:simplepreview_logs = true
  file [SimplePreview Logs]
  RefreshLogs()
enddef

def ReadLine(line: string)
  var clean = substitute(line, '\e\].\{-}\%(\%x07\|\e\\\)', '', 'g')
  clean = substitute(clean, '\e\[[0-?]*[ -/]*[@-~]', '', 'g')
  clean = substitute(clean, '[[:cntrl:]]', '', 'g')
  last_line = strcharpart(clean, 0, 512)
  add(log_lines, strcharpart(clean, 0, LogLineChars))
  if len(log_lines) > LogLimit
    remove(log_lines, 0, len(log_lines) - LogLimit - 1)
  endif
  if empty(url)
    for token in split(clean)
      var candidate = LocalURL(token)
      if !empty(candidate)
        url = candidate
        if open_canvas_when_ready
          open_canvas_when_ready = false
          try
            OpenBrowser(candidate)
          catch /^SimplePreview:/
            echom v:exception
          endtry
        endif
        break
      endif
    endfor
  endif
enddef

def Output(id: number, _channel: channel, data: string)
  if id != generation
    return
  endif
  pending ..= data
  var lines = split(pending, "\n", true)
  pending = remove(lines, -1)
  for line in lines
    ReadLine(line)
  endfor
  # Trim on character boundaries, including when a raw callback splits UTF-8.
  pending = strcharpart(pending, max([0, strchars(pending) - 2048]))
  if !empty(lines)
    RefreshLogs()
  endif
enddef

def Closed(id: number, _channel: channel)
  if id == generation && !empty(pending)
    ReadLine(pending)
    pending = ''
    RefreshLogs()
  endif
enddef

def Exited(id: number, _job: job, code: number)
  if id == generation
    exit_code = code
    phase = 'exited'
    open_canvas_when_ready = false
    if !empty(pending_restart)
      var request = pending_restart
      pending_restart = {}
      try
        LaunchRestart(request)
      catch
        # Retire old output/close callbacks too, so a late partial line cannot
        # overwrite the failure diagnostic when no replacement was launched.
        generation += 1
        phase = 'failed'
        ReadLine('SimplePreview restart failed: ' .. v:exception)
        RefreshLogs()
      endtry
    endif
  endif
enddef

def LaunchRestart(request: dict<any>)
  if !empty(request.canvas)
    if !filereadable(request.canvas)
      throw 'SimplePreview: original Canvas file is unavailable'
    endif
    Launch(request.root, request.command, request.canvas)
    return
  endif
  if ProjectRoot(request.root) != request.root
    throw 'SimplePreview: original project root no longer has package.json'
  endif
  Start(request.command, request.root)
enddef

export def Start(args: list<string> = [], directory: string = '')
  if phase == 'running' || phase == 'stopping'
    throw 'SimplePreview: stop the current session before starting another'
  endif
  var location = directory
  if empty(location)
    location = get(g:, 'simplepreview_root', '')
  endif
  if empty(location) && empty(args)
    var path = CurrentCanvas()
    if !empty(path)
      StartCanvas(path)
      return
    endif
  endif
  var explicit_root = !empty(location)
  if empty(location) && bufnr() == log_buffer && !empty(root)
    location = root
    explicit_root = true
  endif
  if empty(location)
    if &buftype != '' || bufname() =~# '^\a\+://'
      throw 'SimplePreview: use a local project buffer or set g:simplepreview_root'
    endif
    location = empty(bufname()) ? getcwd() : expand('%:p')
  endif
  var project = explicit_root ? ExactProjectRoot(location) : ProjectRoot(location)
  if empty(project)
    if explicit_root
      throw 'SimplePreview: explicit project root must be an existing local directory containing package.json'
    endif
    throw 'SimplePreview: no local package.json found; choose the project root'
  endif
  var argv: list<string> = empty(args) ? get(g:, 'simplepreview_command', ['npm', 'run', 'dev']) : args
  Launch(project, argv)
enddef

def Launch(project: string, args: list<string>, canvas_path: string = '')
  if !has('unix') || !has('job') || !executable('python3')
    throw 'SimplePreview: requires POSIX Vim with +job and Python 3'
  endif
  var argv = copy(args)
  if !empty(argv) && stridx(argv[0], '/') >= 0 && argv[0][0] != '/'
    argv[0] = simplify(project .. '/' .. argv[0])
  endif
  if empty(argv) || !executable(argv[0])
    throw 'SimplePreview: executable not found; install dependencies yourself'
  endif
  for arg in argv
    if arg =~# '[\r\n]'
      throw 'SimplePreview: command arguments must not contain newlines'
    endif
  endfor
  generation += 1
  root = project
  command = copy(argv)
  canvas = canvas_path
  open_canvas_when_ready = false
  url = ''
  pending = ''
  last_line = ''
  log_lines = []
  RefreshLogs()
  exit_code = -1
  phase = 'running'
  server = job_start(['python3', Supervisor] + argv, {
    cwd: project, in_io: 'pipe', out_mode: 'raw', err_io: 'out',
    out_cb: function(Output, [generation]), close_cb: function(Closed, [generation]),
    exit_cb: function(Exited, [generation]), stoponexit: 'term',
  })
  if job_status(server) == 'fail'
    phase = 'failed'
    throw 'SimplePreview: could not launch supervisor'
  endif
enddef

def StopJob()
  open_canvas_when_ready = false
  if phase != 'running' && phase != 'stopping'
    return
  endif
  phase = 'stopping'
  var target = server
  if job_status(target) == 'run'
    job_stop(target, 'term')
  endif
enddef

export def Stop()
  pending_restart = {}
  StopJob()
enddef

export def Restart()
  if empty(command) || empty(root)
    throw 'SimplePreview: no previous command; use Start first'
  endif
  var request = {command: copy(command), root: root, canvas: canvas}
  if empty(canvas) && ProjectRoot(root) != root
    throw 'SimplePreview: original project root no longer has package.json'
  endif
  if phase == 'running' || phase == 'stopping'
    # One explicit queued restart. Repeated requests coalesce; Stop cancels it.
    pending_restart = request
    StopJob()
  else
    LaunchRestart(request)
  endif
enddef

export def Open(path: string = '')
  var current = empty(path) ? CurrentCanvas() : ''
  if !empty(current)
    if phase == 'stopping' || (phase == 'running' && canvas != current)
      throw 'SimplePreview: stop the current session before opening this Canvas'
    endif
    if phase != 'running'
      StartCanvas(current)
    endif
    if empty(url)
      open_canvas_when_ready = true
    else
      OpenBrowser(url)
    endif
    return
  endif
  if phase != 'running' || empty(url) || LocalURL(url) != url
    throw 'SimplePreview: no running local preview URL; check :SimplePreviewStatus'
  endif
  var page = empty(path) ? get(g:, 'simplepreview_path', '/') : path
  var target = PageURL(url, page)
  if empty(target)
    throw 'SimplePreview: page must be an absolute local path using letters, digits, / . _ ~ - (no //, dot segments, query or fragment)'
  endif
  OpenBrowser(target)
enddef

def OpenBrowser(target: string)
  var opener: list<string>
  if has('macunix')
    opener = ['open']
  elseif executable('xdg-open')
    opener = ['xdg-open']
  else
    throw 'SimplePreview: no browser opener; copy the URL from status'
  endif
  var browser = job_start(opener + [target], {in_io: 'null', out_io: 'null', err_io: 'null', stoponexit: ''})
  if job_status(browser) == 'fail'
    throw 'SimplePreview: browser opener failed to start'
  endif
enddef
