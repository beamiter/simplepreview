"""Keep a group-owned lock to detect overlapping managed restart sessions."""
import fcntl
import json
import os
import signal
import sys
import time

lock = open('restart.lock', 'w')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print('OVERLAPPING RESTART', flush=True)
    sys.exit(99)
# An inherited lock held by a TERM-ignoring child verifies full group cleanup,
# not merely exit of the first process in the command.
ready_read, ready_write = os.pipe()
if os.fork() == 0:
    os.close(ready_read)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.write(ready_write, b'1')
    os.close(ready_write)
    while True:
        time.sleep(.05)
os.close(ready_write)
os.read(ready_read, 1)
os.close(ready_read)


def finish(_signal, _frame):
    sys.stdout.write('old session stopped')  # Deliberately unterminated.
    sys.stdout.flush()
    raise SystemExit(0)


signal.signal(signal.SIGTERM, finish)
with open('restart-runs.jsonl', 'a') as output:
    output.write(json.dumps({'cwd': os.getcwd(), 'args': sys.argv[1:]}) + '\n')
print('http://localhost:5173/', flush=True)
while True:
    time.sleep(.05)
