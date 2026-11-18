"""Real ffplay decoding under SDL dummy, not a visible GUI assertion."""
import os
import http.server
import threading
import time
from test_supervisor import alive
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib

REPO = Path(__file__).resolve().parents[1]
VIM = os.environ.get('VIM_TEST_BIN', 'vim')

@unittest.skipUnless(shutil.which('ffplay') and shutil.which('ffmpeg'), 'ffplay/ffmpeg required')
class MediaTests(unittest.TestCase):
    def test_real_image_video_and_disguised_playlist(self):
        with tempfile.TemporaryDirectory(prefix="media ' ") as directory:
            root = Path(directory)
            def chunk(kind, data):
                return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
            image = root / 'red.png'
            image.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 16, 16, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + b'\xff\0\0' * 16) * 16)) + chunk(b'IEND', b''))
            video = root / 'red.avi'
            subprocess.run(['ffmpeg', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=16x16:d=0.2', '-c:v', 'mpeg4', str(video)], check=True, timeout=10)
            playlist = root / 'list.mp4'
            requests = []
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    requests.append(self.path)
                    self.send_response(404)
                    self.end_headers()
                def log_message(self, *_args):
                    pass
            listener = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            worker = threading.Thread(target=listener.serve_forever, daemon=True)
            worker.start()
            self.addCleanup(listener.server_close)
            self.addCleanup(listener.shutdown)
            playlist.write_text(f'#EXTM3U\nhttp://127.0.0.1:{listener.server_port}/forbidden\n' + str(image) + '\n')
            def q(value):
                return "'" + str(value).replace("'", "''") + "'"
            script = root / 'test.vim'
            script.write_text(f'''vim9script
execute 'set rtp^=' .. fnameescape({q(REPO)})
runtime plugin/simplepreview.vim
simplepreview_media#Preview('image', {q(image)})
sleep 400m
assert_equal('running', simplepreview_media#Status().state)
assert_equal('', simplepreview_media#Status().last_output)
SimplePreviewMediaStop
for _ in range(150)
  if simplepreview_media#Status().state != 'stopping'
    break
  endif
  sleep 20m
endfor
simplepreview_media#Preview('video', {q(video)})
for _ in range(200)
  if simplepreview_media#Status().state != 'running'
    break
  endif
  sleep 20m
endfor
assert_equal('exited', simplepreview_media#Status().state)
assert_equal('', simplepreview_media#Status().last_output)
simplepreview_media#Preview('video', {q(playlist)})
for _ in range(200)
  if simplepreview_media#Status().state != 'running'
    break
  endif
  sleep 20m
endfor
assert_match('Invalid data', simplepreview_media#Status().last_output)
writefile(v:errors, {q(root / 'errors')})
qa!
''')
            env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
            subprocess.run([VIM, '-Nu', 'NONE', '-n', '-i', 'NONE', '-es', '-S', str(script)], env=env, check=True, timeout=20)
            self.assertEqual('', (root / 'errors').read_text())
            self.assertEqual([], requests)

    def test_actual_vim_exit_cleans_media(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pidfile = root / 'pids'
            stub = root / 'ffplay'
            stub.write_text("#!/usr/bin/env python3\nimport os,time\nchild=os.fork()\nif child == 0:\n time.sleep(30)\nelse:\n open(os.environ['SP_MEDIA_PIDS'],'w').write(f'{os.getpid()} {child}')\n time.sleep(30)\n")
            stub.chmod(0o700)
            image = root / 'test.png'
            image.write_bytes(b'not decoded by stub')
            script = root / 'quit.vim'
            script.write_text(f"set rtp^={REPO}\nruntime plugin/simplepreview.vim\ncall simplepreview_media#Preview('image', '{image}')\nlet attempts=0\nwhile !filereadable('{pidfile}') && attempts < 100\n sleep 20m\n let attempts += 1\nendwhile\nqa!\n")
            env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], SP_MEDIA_PIDS=str(pidfile))
            subprocess.run([VIM, '-Nu', 'NONE', '-n', '-i', 'NONE', '-es', '-S', str(script)], env=env, check=True, timeout=10)
            pids = [int(value) for value in pidfile.read_text().split()]
            try:
                deadline = time.monotonic() + 5
                while any(alive(pid) for pid in pids) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertFalse(any(alive(pid) for pid in pids))
            finally:
                for pid in pids:
                    if alive(pid):
                        os.kill(pid, 9)
