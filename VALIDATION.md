# Validation record

Cloud Linux, 2026-11-18. Vim 9.1.2141 and Vim 9.2.1364 built from the official
Vim repository. The complete suite passed on both versions.

- `make check`: passed all 9 Python lifecycle tests and the Vim9 integration
  suite. This includes a real temporary localhost HTTP server, refusal after
  stop, ignored-TERM descendants, natural leader exit, control EOF, actual Vim
  exit, and flood output with the consumer deliberately not reading.
- Vim suite: hostile URL table, ANSI/chunk-split URL recognition, no auto-start
  on source/open/write, no auto-browser launch, fake browser argv capture,
  project paths with spaces/apostrophes, literal shell metacharacters,
  nearest-root discovery, relative executable resolution, duplicate start,
  repeated stop/restart, final unterminated output, and nonzero exit status.
- Help-tag generation, Python bytecode compilation and whitespace checks passed.

During independent review, stdout backpressure was found to block stopping.
It was corrected with nonblocking writes and a bounded 64 KiB queue; overload
may drop output. A separate review finding about project-relative executable
resolution was also corrected. Both now have regression coverage. The independent reviewer reran the full
suite on Vim 9.2.1364 and found no remaining first-version blockers.

Not tested: a real React/Vite dependency stack or browser-rendered page; macOS;
Windows (unsupported). Browser dispatch is tested via a stub on Linux. At initial local validation, no user project script was run or project
dependencies installed; the source was retained locally before publication
was separately authorized.
