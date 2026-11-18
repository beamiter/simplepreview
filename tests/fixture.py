"""A harmless dev-server stand-in, never installs or runs project code."""
import os
import sys
import time
from pathlib import Path

Path('observed.txt').write_text(repr([os.getcwd(), *sys.argv[1:]]))
print('http://127.0.0.1:5173@evil.example', flush=True)
print('http://localhost.evil.example:5173/', flush=True)
print('http://0.0.0.0:5173/', flush=True)
sys.stdout.write('\x1b[32mLocal: http://local')
sys.stdout.flush()
time.sleep(0.1)
print('host:5173/\x1b[0m', flush=True)
while True:
    time.sleep(0.1)
