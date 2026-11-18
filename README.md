# SimplePreview

An independent Vim9 plugin for **existing local web projects** and **Cursor Canvases**.
It starts a preview on request and opens it in your external browser.
It also explicitly previews local images/videos in an external ffplay window.

## Requirements

- Vim 9 with `+job` and `+channel`.
- POSIX host and Python 3 with `os.waitid` / `os.WNOWAIT` support.
  Linux is tested. macOS has a browser opener branch but is **not yet verified**;
  unsupported Python builds fail before starting the project. Windows is not
  supported in this first version.
- For web projects, a `package.json`, dependencies already installed, and a
  working foreground dev command. For React/Vite this is usually `npm run dev`.
- `xdg-open` on Linux or `open` on macOS, for the optional browser command.

## Install locally

Place this directory at `~/.vim/pack/local/start/simplepreview` (or add it to your
plugin manager as a local directory). Generate help tags with
`:helptags ~/.vim/pack/local/start/simplepreview/doc`.
No command runs merely by installing, sourcing, opening, or saving a file.

## Use

Open a local file in an existing project, then:

```vim
:SimplePreviewStart
:SimplePreviewStatus
:SimplePreviewLogs
:SimplePreviewOpen
:SimplePreviewStop
```

Start uses the nearest ancestor `package.json` of the current file, or Vim's
working directory for an unnamed buffer. It runs `npm run dev` by default and
never changes Vim's working directory. Status shows the state, project root,
argv, first accepted local URL, exit code, and latest output line. If the server
reports a different available port, the actual printed port is used. A port
conflict without a URL remains visible in status; no unrelated process is killed.
Use `:SimplePreviewLogs` to inspect earlier build errors in a read-only scratch
window. It retains the latest 200 completed output lines, capped at 512 Unicode
characters per line, strips terminal styling/hyperlink escapes, and never writes
logs to a project file. Reopening the command reuses the existing log window;
closing it does not stop the server. Undo history is disabled for this window. Starting a new session clears the log tail.
From this log window, Start can reuse the previous session's project directory.

To explicitly use a different command:

```vim
:SimplePreviewStart pnpm run dev
```

For projects with a separate web command (rather than their desktop/Electron
`dev` script), select it explicitly. To open a non-root entry page:

```vim
:SimplePreviewStart pnpm run dev:web
:SimplePreviewOpen /web-index.html
```

The command and page are examples, not auto-detected project conventions. The
server must first print an eligible loopback origin. An explicit page changes
only the path on that origin; it never chooses a different host or port. Without
an argument, Open uses `g:simplepreview_path` (default `/`), which you may set in
your own Vim configuration. Use `/` explicitly to override a configured page.
Page paths accept ASCII letters, digits, `.`, `_`, `~`, `-` and single slashes;
`//`, dot segments, percent escapes, spaces, backslashes, queries and fragments
are rejected. No paths or configuration are taken from repository files/output.

The Start command uses Vim's `<f-args>` rules, **not shell parsing**. For arguments
containing spaces use the typed API or configuration:

```vim
let g:simplepreview_root = '/home/me/project with spaces'
let g:simplepreview_command = ['npm', 'run', 'dev', '--', '--host', '127.0.0.1']
let g:simplepreview_path = '/web-index.html'  " optional explicit entry page
" Explicit API, including a project-relative executable:
call simplepreview#Start(['./node_modules/.bin/vite', '--host', '127.0.0.1'], '/home/me/app')
```

Explicit roots (`g:simplepreview_root` or the API's directory argument) must be
existing local directories containing their own `package.json`. A typo, file
path, or markerless subdirectory is rejected instead of silently running an
ancestor project. Upward discovery is used only when no root was explicitly
provided. The log window's remembered root is also checked exactly.

Configuration does not start anything. No commands are read from repository
configuration files or inferred from their content; `package.json` is only a
root marker. Running a project command still executes that project's code and
any package-manager lifecycle hooks: use only projects you trust. Passing
`sh -c ...` explicitly opts into a shell; the plugin never adds one for you.

Use `:SimplePreviewRestart` to explicitly repeat the last launched argv and
project directory, including a custom `pnpm run dev:web`. It does not fall back
to the current default command, current buffer or a changed root override. If a
session is still running, the replacement waits until its supervisor finishes
process-group cleanup. Repeated requests coalesce into one pending restart;
`:SimplePreviewStop` or quitting Vim cancels it. Status exposes `restart_pending`.
A missing original project marker cancels the restart instead of selecting an
ancestor project. Restart errors remain in status/logs; they never auto-retry.
Restart does not open a browser. With no previous command, use Start first.

There is one managed session per Vim instance. Stop is asynchronous: wait for
`state: exited` before starting another project. Repeated Stop is safe. Vim exit
or a closed control pipe also cleans up the managed process group. Ordinary
foreground descendants are terminated, then killed after a one-second grace
period. A script that deliberately daemonizes or creates a separate session is
outside this ownership boundary and must not be used as a dev command.

## URL and output safety

- Open is separate from Start; output never automatically launches a browser.
- Only exact `http://` or `https://` origins with an explicit port 1–65535 on
  `localhost`, `127.0.0.1`, or `[::1]` are accepted. A trailing `/` is allowed.
- URLs in output with external hosts, `0.0.0.0`, credentials, paths, queries,
  fragments or shell/browser flags are rejected. Only the first accepted origin
  is retained. A non-root page must be chosen explicitly as described above.
- The plugin uses argv lists, not shell concatenation, for both server and
  browser. Paths with spaces and apostrophes are supported.
- Retained output is bounded (status plus the diagnostic tail). Under heavy backpressure the supervisor may drop
  log chunks rather than block cleanup. Status is not a complete log viewer.
- A loopback address is not proof of trustworthy content. The plugin does not
  authenticate the server or control redirects performed by a browser.

If a server prints no eligible URL (for example only a network address or base
path), check its settings and configure it to advertise a loopback root URL.
No port guessing, URL probing, browser auto-refresh injection or existing-server
attachment is performed. Open hands the URL to the OS; it cannot confirm that a
browser successfully displayed the page.

## TSX boundaries

### Cursor Canvases

From a saved `~/.cursor/projects/<workspace>/canvases/<name>.canvas.tsx` buffer,
run `:SimplePreviewOpen` to start and open a local browser preview. Use
`:SimplePreviewStart` without a project root override to start it without opening
the browser. Save changes and
reload the browser to see them. Status, Stop, and Restart use the same managed
session as a web project.

Canvas preview requires Node.js, the runtime bundled with Cursor, and the
TypeScript compiler. SimplePreview looks for the runtime in the installation
that provides `cursor` on PATH and for the compiler in the SimpleCC-managed
TypeScript installation. For other installations, set
`g:simplepreview_canvas_runtime` and `g:simplepreview_canvas_typescript` to the
paths of `canvas-runtime.esm.js` and `typescript.js`. The browser mounts the
saved component with the Cursor Canvas SDK. Features that depend on the Cursor
editor, such as agent actions and publishing, require the native Canvas view.

### Web projects

SimpleTreeSitter supplies TSX highlighting and SimpleCC can use
`typescript-language-server` for `typescriptreact` buffers. SimplePreview is
independent of both. The project's dev server supplies React Fast Refresh/HMR
when **saved files** change. Unsaved-buffer preview, a DOM pane inside Vim,
standalone-component harness generation, SSH port forwarding, remote workspaces,
and dependency installation are deliberately not part of this first version.
A lone `.tsx` file still needs a working app entry point, dependencies and any
providers/router/styles. Vite transpilation alone is not TypeScript typechecking.

## Tests

```sh
make check VIM=/path/to/vim
```

Tests use temporary fake projects, a harmless Python HTTP server, and a fake
Linux browser opener. They do not install packages, run a real project's scripts,
or launch a real browser. Coverage includes hostile URLs, split/ANSI output,
nearest project discovery, spaces/apostrophes and literal argv, no automatic
start/open, repeated stop/restart, nonzero exit, relative executables, process
group cleanup after stop/EOF/leader exit, output-flood backpressure, bounded/reusable diagnostic logs, and explicit
non-root entry paths (including a synthetic root-404/page-200 web server), and
explicit restart retention/coalescing/cancellation with a group-owned lock.
These are not a React/Vite end-to-end or macOS verification claim.

## Images and videos (external window)

```vim
:SimplePreviewImage
:SimplePreviewVideo /home/me/Videos/clip.mp4
:SimplePreviewMediaStatus
:SimplePreviewMediaStop
```

These explicit commands launch **ffplay in a separate graphical window**, not a
Vim split or terminal-native image/video renderer. No media is launched on file
open/save. Without a path they use the saved current buffer; otherwise the whole
argument is a literal filename (spaces allowed, no quotes, shell expansion or
`%` expansion). The typed API also accepts literal paths:
`call simplepreview_media#Preview('image', '/home/me/photo with spaces.png')`.
No project/package.json is needed. The file on disk is previewed, not unsaved edits.

Install ffplay (usually the FFmpeg package) yourself. Nothing is installed by the
plugin. Requires the existing POSIX/Python supervisor and a working graphical
session; SSH/headless terminals do not automatically get a local player window.
Images: PNG, JPEG, WebP, BMP. Videos: MP4/M4V/MOV, MKV/WebM, AVI. Codec availability
depends on your FFmpeg build. SVG, GIF, playlists, URLs, directories and special
files are intentionally unsupported. Symlinks resolve to an existing regular
file; the target's extension is checked. Filenames are absolute argv values,
never shell commands or desktop URL/file associations. The demuxer allowlist
rejects disguised playlists; only the `file` protocol is enabled. ffplay's
external MOV references remain disabled by default. These restrictions are **not
a sandbox**: native media decoders still parse the selected file, may use CPU or
memory, and have their own vulnerabilities. Preview trusted media and keep
FFmpeg updated. No hard size/memory/CPU isolation or adversarial file-race
protection is promised.

One media session is managed independently of the web/Canvas session. Stop and
Vim exit clean up its owned process group using the same supervisor; wait until
it is no longer stopping before opening another. No unrelated players are
closed. MediaStatus reports the path, backend, process state, exit code and a
bounded escaped output fragment. `running` only means the process is alive;
`exited`/exit code 0 does **not** prove successful display or decoding (ffplay can
exit 0 after input errors). Inspect `last_output` and the player window.

Anvil/Forge/Ember/Frost have differing static-image capabilities; this backend
does not depend on their Kitty graphics support and does not claim inline video.
Linux tests cover argv boundaries, managed cleanup, real synthetic PNG/AVI
with SDL's dummy video driver, and a disguised playlist rejection. This is not
four-terminal GUI, real monitor/audio, macOS, or SSH end-to-end validation.
