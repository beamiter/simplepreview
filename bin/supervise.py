#!/usr/bin/env python3
"""Own one explicitly requested foreground command and its POSIX process group."""
import os
import selectors
import signal
import subprocess
import sys
import time


def main():
    if os.name != 'posix' or len(sys.argv) < 2:
        return 2
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)
    try:
        child = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 start_new_session=True)
    except OSError as exc:
        print('SimplePreview: cannot start command: ' + str(exc), flush=True)
        return 127
    selector = selectors.DefaultSelector()
    selector.register(sys.stdin.buffer, selectors.EVENT_READ, 'control')
    selector.register(child.stdout, selectors.EVENT_READ, 'output')
    output_open = True
    output_buffer = bytearray()
    os.set_blocking(sys.stdout.fileno(), False)

    def forward(timeout):
        nonlocal stopping, output_open
        for key, _ in selector.select(timeout):
            data = os.read(key.fileobj.fileno(), 4096)
            if key.data == 'control':
                stopping = True  # Input or EOF: Vim closed or requested stop.
                selector.unregister(key.fileobj)
            elif data:
                # Bounded, lossy logging under backpressure. Cleanup must never
                # depend on the consumer reading stdout.
                if len(output_buffer) + len(data) <= 65536:
                    output_buffer.extend(data)
            else:
                selector.unregister(key.fileobj)
                output_open = False
        if output_buffer:
            try:
                sent = os.write(sys.stdout.fileno(), output_buffer)
                del output_buffer[:sent]
            except BlockingIOError:
                pass
            except BrokenPipeError:
                stopping = True
                output_buffer.clear()

    def signal_group(sig):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass

    try:
        # Keep the leader unreaped until group cleanup, preventing PID reuse.
        while not stopping:
            forward(0.05)
            if os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT):
                break
    finally:
        signal_group(signal.SIGTERM)
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            forward(0.05)
        signal_group(signal.SIGKILL)
        code = child.wait()
        deadline = time.monotonic() + 0.2
        while output_open and time.monotonic() < deadline:
            forward(0.02)
        selector.close()
        child.stdout.close()
    return code if code >= 0 else 128 - code


if __name__ == '__main__':
    if not all(hasattr(os, name) for name in ('waitid', 'WNOWAIT', 'P_PID')):
        print('SimplePreview requires POSIX Python with waitid/WNOWAIT', flush=True)
        sys.exit(2)
    sys.exit(main())
