#!/usr/bin/env python3
"""Real tmux smoke; uses only temporary config and a local mock provider.
Run: python3 tests/skills_pty_smoke.py /path/to/bone
"""
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time

requests = []


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        call_number = len(requests)
        if call_number <= 2:
            arguments = {'action': 'read', 'name': 'demo', 'file':
                         'references/note.txt' if call_number == 1 else '../secret.txt'}
            delta = {'tool_calls': [{'index': 0, 'id': f'call_{call_number}', 'type': 'function',
                                    'function': {'name': 'skill', 'arguments': json.dumps(arguments)}}]}
            finish = 'tool_calls'
        else:
            delta, finish = {'content': 'SMOKE_RESPONSE'}, 'stop'
        data = {'id': 'smoke', 'object': 'chat.completion.chunk', 'choices': [
            {'index': 0, 'delta': delta, 'finish_reason': finish}]}
        body = ('data: ' + json.dumps(data) + '\n\ndata: [DONE]\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


binary = str(Path(sys.argv[1]).resolve())
catalog = Path(__file__).resolve().parents[1]
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='bone-skills-pty-') as temp:
    root = Path(temp)
    cfg, project = root / 'config', root / 'project'
    cfg.mkdir()
    (cfg / 'init.lua').write_text('-- isolated smoke config\n')
    project.mkdir()
    (project / '.git').touch()
    (cfg / 'providers.yaml').write_text(
        'version: 1\nactive: smoke\nproviders:\n  smoke:\n'
        '    label: Smoke\n    handler: openai\n    model: smoke\n'
        f'    base_url: http://127.0.0.1:{server.server_port}\n')
    for relative in ('lib/skill.lua', 'tools/skill.lua', 'commands/skill.lua'):
        destination = cfg / 'lua' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(catalog / relative, destination)
    skill = project / '.agents/skills/demo'
    skill.mkdir(parents=True)
    (skill / 'SKILL.md').write_text('---\nname: demo\ndescription: Smoke demo\n---\nSKILL_BODY_MARKER\n')
    (skill / 'references').mkdir()
    (skill / 'references/note.txt').write_text('REFERENCE_MARKER')
    global_skill = cfg / 'skills/demo'
    global_skill.mkdir(parents=True)
    (global_skill / 'SKILL.md').write_text('---\nname: demo\ndescription: Global demo\n---\nGLOBAL_BODY_MARKER\n')
    socket = str(root / 'tmux.sock')

    def tmux(*args, check=True):
        return subprocess.run(['tmux', '-S', socket, *args], text=True,
                              capture_output=True, check=check, timeout=5)

    def capture():
        return tmux('capture-pane', '-p', '-S', '-200', '-t', 'smoke').stdout

    def wait_for(predicate, label, timeout=20):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.2)
        raise AssertionError(label + '\n' + capture())

    def send(text):
        tmux('send-keys', '-t', 'smoke', '-l', text)
        time.sleep(.3)
        tmux('send-keys', '-t', 'smoke', 'Enter')

    command = f'cd {shlex.quote(str(project))} && BONE_DIR={shlex.quote(str(cfg))} {shlex.quote(binary)}; echo SMOKE_EXIT:$?; sleep 30'
    try:
        tmux('new-session', '-d', '-s', 'smoke', '-x', '110', '-y', '35', command)
        time.sleep(2)
        send('/skill')
        # GNU realpath may ask for approval; inspect and accept only this fixture guard.
        time.sleep(1)
        screen = capture()
        if 'realpath' in screen and ('Allow' in screen or 'Approve' in screen or 'approve' in screen):
            tmux('send-keys', '-t', 'smoke', 'Enter')
        wait_for(lambda: 'Smoke demo' in capture(), 'listing did not display')
        assert not requests, 'listing submitted a model turn'
        send('/skill missing')
        wait_for(lambda: 'skill not found' in capture(), 'missing error did not display')
        assert not requests, 'error submitted a model turn'
        send('/skill demo')
        wait_for(lambda: bool(requests), 'skill prompt did not reach provider')
        encoded = json.dumps(requests[0])
        assert 'SKILL_BODY_MARKER' in encoded and 'Directory:' in encoded, encoded
        assert 'Available skills' in encoded and 'Smoke demo' in encoded, encoded
        wait_for(lambda: 'SMOKE_RESPONSE' in capture(), 'response not rendered')
        assert 'GLOBAL_BODY_MARKER' not in encoded, 'global skill incorrectly won'
        assert len(requests) == 3, 'expected reference and traversal tool calls'
        results = [m for m in requests[-1]['messages'] if m['role'] == 'tool']
        assert len(results) == 2, results
        assert 'REFERENCE_MARKER' in results[0]['content'], results
        assert 'invalid file path' in results[1]['content'], results
        tmux('resize-window', '-t', 'smoke', '-x', '80', '-y', '24')
        assert 'SMOKE_RESPONSE' in capture()
        tmux('send-keys', '-t', 'smoke', 'C-c')
        time.sleep(.3)
        tmux('send-keys', '-t', 'smoke', 'C-c')
        wait_for(lambda: 'SMOKE_EXIT:0' in capture(), 'unclean shutdown')
        print('skills PTY smoke passed: listing/errors no turn, prompt/body/index, resize, clean shutdown')
    finally:
        tmux('kill-server', check=False)
        server.shutdown()
