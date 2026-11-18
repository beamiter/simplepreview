vim9script
const Supervisor = expand('<sfile>:p:h:h') .. '/bin/supervise.py'
var player: job
var phase = 'idle'
var target = ''
var kind = ''
var code = -1
var generation = 0
var last_output = ''

export def Status(): dict<any>
  return {state: phase, path: target, kind: kind, backend: 'external ffplay', exit_code: code, last_output: last_output}
enddef

def Exited(id: number, _job: job, result: number)
  if id != generation
    return
  endif
  code = result
  phase = result == 0 ? 'exited' : 'failed'
enddef

def Output(id: number, _channel: channel, text: string)
  if id == generation
    var cleaned = trim(substitute(text, '[\r\n]', ' ', 'g'))
    if !empty(cleaned)
      last_output = strcharpart(strtrans(cleaned), 0, 512)
    endif
  endif
enddef

export def Stop()
  var owned = player
  if (phase == 'running' || phase == 'stopping') && job_status(owned) == 'run'
    phase = 'stopping'
    ch_close_in(job_getchannel(owned))
  endif
enddef

export def Preview(media_kind: string, path: string = '')
  if phase == 'running' || phase == 'stopping'
    throw 'SimplePreview: stop the current media session first'
  endif
  if !has('unix') || !executable('python3') || !executable('ffplay')
    throw 'SimplePreview: media requires POSIX, Python 3 and ffplay; install dependencies yourself'
  endif
  var name = path
  if empty(name)
    if &buftype != '' || empty(bufname())
      throw 'SimplePreview: choose a saved local media file'
    endif
    name = expand('%:p')
  endif
  if name =~# '[\r\n]' || name =~# '^\a[[:alnum:]+.-]*://'
    throw 'SimplePreview: only local media paths without newlines are accepted'
  endif
  name = resolve(fnamemodify(name, ':p'))
  if getftype(name) != 'file' || !filereadable(name)
    throw 'SimplePreview: media must be a readable regular file'
  endif
  var ext = tolower(fnamemodify(name, ':e'))
  var formats = ''
  if media_kind == 'image' && index(['png', 'jpg', 'jpeg', 'webp', 'bmp'], ext) >= 0
    formats = 'png_pipe,jpeg_pipe,webp_pipe,bmp_pipe'
  elseif media_kind == 'video' && index(['mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi'], ext) >= 0
    formats = 'mov,matroska,webm,avi'
  else
    throw 'SimplePreview: unsupported media extension (playlists and SVG are not supported)'
  endif
  # No shell, URL handler, player configuration, playlist or network protocol.
  # Demuxer allowlist also rejects a playlist renamed to a permitted extension.
  var argv = ['ffplay', '-hide_banner', '-loglevel', 'error',
    '-protocol_whitelist', 'file', '-format_whitelist', formats,
    '-window_title', 'SimplePreview ' .. media_kind]
  if media_kind == 'video'
    add(argv, '-autoexit')
  endif
  # Absolute filename is an argv value, never parsed as an option or expression.
  argv += ['-i', name]
  target = name
  kind = media_kind
  code = -1
  last_output = ''
  generation += 1
  phase = 'running'
  player = job_start(['python3', Supervisor] + argv, {
    in_io: 'pipe', out_mode: 'raw', err_io: 'out', out_cb: function(Output, [generation]), stoponexit: 'term',
    exit_cb: function(Exited, [generation]),
  })
  if job_status(player) == 'fail'
    phase = 'failed'
    throw 'SimplePreview: media supervisor failed to start'
  endif
enddef
