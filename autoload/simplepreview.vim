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

# Exact loopback origins only: no credentials, path, DNS suffix or query.
export def LocalURL(token: string): string
  var m = matchlist(token, '^\(https\?\)://\(localhost\|127\.0\.0\.1\|\[::1\]\):\([0-9]\{1,5}\)/\?$')
  if empty(m) || str2nr(m[3]) < 1 || str2nr(m[3]) > 65535
    return ''
  endif
  return m[1] .. '://' .. m[2] .. ':' .. m[3] .. '/'
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
          exit_code: exit_code, last_line: last_line}
enddef

def ReadLine(line: string)
  var clean = substitute(line, '\e\[[0-?]*[ -/]*[@-~]', '', 'g')
  clean = substitute(clean, '[[:cntrl:]]', '', 'g')
  last_line = strpart(clean, 0, 512)
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
  pending = strpart(pending, max([0, strlen(pending) - 8192]))
enddef

def Closed(id: number, _channel: channel)
  if id == generation && !empty(pending)
    ReadLine(pending)
    pending = ''
  endif
enddef

def Exited(id: number, _job: job, code: number)
  if id == generation
    exit_code = code
    phase = 'exited'
  endif
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

export def Stop()
  if phase != 'running' && phase != 'stopping'
    return
  endif
  phase = 'stopping'
  if job_status(server) == 'run'
    job_stop(server, 'term')
  endif
enddef

export def Open()
  if phase != 'running' || empty(url) || LocalURL(url) != url
    throw 'SimplePreview: no running local preview URL; check :SimplePreviewStatus'
  endif
  var opener: list<string>
  if has('macunix')
    opener = ['open']
  elseif executable('xdg-open')
    opener = ['xdg-open']
  else
    throw 'SimplePreview: no browser opener; copy the URL from status'
  endif
  var browser = job_start(opener + [url], {in_io: 'null', out_io: 'null', err_io: 'null', stoponexit: ''})
  if job_status(browser) == 'fail'
    throw 'SimplePreview: browser opener failed to start'
  endif
enddef
