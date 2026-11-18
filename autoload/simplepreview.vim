vim9script
const Supervisor = expand('<sfile>:p:h:h') .. '/bin/supervise.py'
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
  if ProjectRoot(request.root) != request.root
    throw 'SimplePreview: original project root no longer has package.json'
  endif
  Start(request.command, request.root)
enddef

export def Start(args: list<string> = [], directory: string = '')
  if phase == 'running' || phase == 'stopping'
    throw 'SimplePreview: stop the current session before starting another'
  endif
  if !has('unix') || !has('job') || !executable('python3')
    throw 'SimplePreview: requires POSIX Vim with +job and Python 3'
  endif
  var location = directory
  if empty(location)
    location = get(g:, 'simplepreview_root', '')
  endif
  if empty(location) && bufnr() == log_buffer && !empty(root)
    location = root
  endif
  if empty(location)
    if &buftype != '' || bufname() =~# '^\a\+://'
      throw 'SimplePreview: use a local project buffer or set g:simplepreview_root'
    endif
    location = empty(bufname()) ? getcwd() : expand('%:p')
  endif
  var project = ProjectRoot(location)
  if empty(project)
    throw 'SimplePreview: no local package.json found; choose the project root'
  endif
  var argv: list<string> = copy(empty(args) ? get(g:, 'simplepreview_command', ['npm', 'run', 'dev']) : args)
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
  var request = {command: copy(command), root: root}
  if ProjectRoot(root) != root
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
  if phase != 'running' || empty(url) || LocalURL(url) != url
    throw 'SimplePreview: no running local preview URL; check :SimplePreviewStatus'
  endif
  var page = empty(path) ? get(g:, 'simplepreview_path', '/') : path
  var target = PageURL(url, page)
  if empty(target)
    throw 'SimplePreview: page must be an absolute local path using letters, digits, / . _ ~ - (no //, dot segments, query or fragment)'
  endif
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
