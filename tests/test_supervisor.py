import os
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

SUPERVISOR = Path(__file__).resolve().parents[1] / 'bin' / 'supervise.py'


def alive(pid):
    # A dead descendant may remain a zombie until the container init reaps it.
    stat = Path(f'/proc/{pid}/stat')
    if stat.exists() and stat.read_text().split()[2] == 'Z':
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


@unittest.skipUnless(os.name == 'posix' and hasattr(os, 'WNOWAIT'), 'POSIX required')
class SupervisorTests(unittest.TestCase):
    def launch(self, script):
        proc = subprocess.Popen([sys.executable, str(SUPERVISOR), sys.executable,
                                 '-u', '-c', script], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.cleanup, proc)
        return proc

    def cleanup(self, proc):
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        for stream in [proc.stdin, proc.stdout, proc.stderr]:
            if stream and not stream.closed:
                stream.close()

    def group_case(self, action):
        with tempfile.TemporaryDirectory() as temp:
            pidfile = Path(temp) / 'pid'
            script = f'''import os, signal, time
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open({str(pidfile)!r}, 'w').write(str(os.getpid()))
    while True: time.sleep(.01)
while not os.path.exists({str(pidfile)!r}): time.sleep(.01)
print('ready', flush=True)
'''
            script += 'exit(7)' if action == 'natural' else 'time.sleep(60)'
            proc = self.launch(script)
            self.assertEqual(proc.stdout.readline(), b'ready\n')
            pid = int(pidfile.read_text())
            if action == 'eof':
                proc.stdin.close()
            elif action == 'term':
                proc.terminate()
            elif action == 'control':
                proc.stdin.write(b'stop\n')
                proc.stdin.flush()
            proc.wait(timeout=5)
            for _ in range(50):
                if not alive(pid):
                    break
                time.sleep(.02)
            self.assertFalse(alive(pid), f'descendant {pid} survived {action}')
            if action == 'natural':
                self.assertEqual(proc.returncode, 7)

    def test_eof_cleans_children(self): self.group_case('eof')
    def test_term_cleans_children(self): self.group_case('term')
    def test_control_cleans_children(self): self.group_case('control')
    def test_natural_exit_cleans_children(self): self.group_case('natural')

    def test_output_and_exit(self):
        proc = self.launch('print("hello"); exit(3)')
        proc.wait(timeout=5)
        self.assertEqual(proc.stdout.read(), b'hello\n')
        self.assertEqual(proc.returncode, 3)

    def test_backpressure_stop(self):
        proc = self.launch('import os;\nwhile True: os.write(1, b"x" * 4096)')
        time.sleep(.2)  # Deliberately do not consume stdout.
        proc.terminate()
        proc.wait(timeout=4)
        self.assertIsNotNone(proc.returncode)

    def test_http_server_lifecycle(self):
        proc = self.launch("""from http.server import HTTPServer, BaseHTTPRequestHandler
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'<h1>preview fixture</h1>')
    def log_message(self, *args): pass
server = HTTPServer(('127.0.0.1', 0), Handler)
print('http://127.0.0.1:%d/' % server.server_port, flush=True)
server.serve_forever()
""")
        url = proc.stdout.readline().decode().strip()
        with urllib.request.urlopen(url, timeout=2) as response:
            self.assertIn(b'preview fixture', response.read())
        proc.terminate()
        proc.wait(timeout=4)
        with self.assertRaises(OSError):
            urllib.request.urlopen(url, timeout=.5)

    @unittest.skipUnless(os.environ.get('VIM_TEST_BIN'), 'run via make check for Vim integration')
    def test_vim_exit_cleans_children(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'package.json').write_text('{}')
            pidfile = root / 'child.pid'
            worker = root / 'worker.py'
            worker.write_text("""import os, signal, time
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open('child.pid', 'w').write(str(os.getpid()))
    while True: time.sleep(.01)
time.sleep(60)
""")
            script = root / 'exit.vim'
            repo = str(SUPERVISOR.parent.parent)
            script.write_text('set rtp^=' + repo + '\n'
                              'runtime plugin/simplepreview.vim\n'
                              'call simplepreview#Start(' + json.dumps([sys.executable, str(worker)])
                              + ', ' + json.dumps(temp) + ')\n'
                              'for i in range(100)\n'
                              '  if filereadable(' + json.dumps(str(pidfile)) + ') | break | endif\n'
                              '  sleep 20m\nendfor\nqa!\n')
            result = subprocess.run([os.environ['VIM_TEST_BIN'], '-Nu', 'NONE', '-n', '-i',
                                     'NONE', '-es', '-S', str(script)],
                                    capture_output=True, timeout=6)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(pidfile.exists(), 'Vim never started fixture')
            pid = int(pidfile.read_text())
            for _ in range(150):
                if not alive(pid):
                    break
                time.sleep(.02)
            self.assertFalse(alive(pid), 'child survived actual Vim exit')

    def test_nonroot_web_entry(self):
        # Models a separate dev:web server without installing/running Orca.
        proc = self.launch("""from http.server import HTTPServer, BaseHTTPRequestHandler
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == '/web-index.html' else 404)
        self.end_headers()
        self.wfile.write(b'<h1>web entry fixture</h1>')
    def log_message(self, *args): pass
server = HTTPServer(('127.0.0.1', 0), Handler)
print('http://127.0.0.1:%d/' % server.server_port, flush=True)
server.serve_forever()
""")
        origin = proc.stdout.readline().decode().strip()
        with self.assertRaises(urllib.error.HTTPError) as missing:
            urllib.request.urlopen(origin, timeout=2)
        self.assertEqual(missing.exception.code, 404)
        with urllib.request.urlopen(origin + 'web-index.html', timeout=2) as response:
            self.assertEqual(response.status, 200)
            self.assertIn(b'web entry fixture', response.read())

    def test_missing_executable(self):
        result = subprocess.run([sys.executable, str(SUPERVISOR), '/missing-command'],
                                input=b'', capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 127)
        self.assertIn(b'cannot start', result.stdout)


if __name__ == '__main__':
    unittest.main()
