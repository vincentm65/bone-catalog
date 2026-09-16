#!/usr/bin/env python3
"""Real tmux PTY smoke for the plugin catalog layout.

Covers, against a real built binary and a temporary BONE_DIR:
  A. `bone catalog` (the same UI the /catalog popup runs): legacy flat files
     (lua/tools, lua/commands, lua/lib, lua/themes) migrate byte-verbatim into
     lua/plugins/<name>/ and the remaining items install fresh from the local
     catalog into the plugin layout.
  B. The main TUI: migrated plugin commands work (/skill), plugin-shipped
     themes load (/themes apply nord), and plugin-registered tools are
     advertised to the provider (web_search, task_loop).
  C. Disabling a plugin via canonical config (plugins.disabled) unregisters
     its tool; re-enabling restores it.

Run: python3 tests/plugin_pty_smoke.py /path/to/bone
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
        data = {'id': 'smoke', 'object': 'chat.completion.chunk', 'choices': [
            {'index': 0, 'delta': {'content': 'SMOKE_RESPONSE'}, 'finish_reason': 'stop'}]}
        body = ('data: ' + json.dumps(data) + '\n\ndata: [DONE]\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def tool_names(body):
    return {t.get('function', {}).get('name') for t in body.get('tools', []) if isinstance(t, dict)}


binary = str(Path(sys.argv[1]).resolve())
catalog = Path(__file__).resolve().parents[1]
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()

socket = '/tmp/bone-plugin-pty-smoke.sock'
subprocess.run(['tmux', '-S', socket, 'kill-server'], check=False, capture_output=True)


def tmux(*args, check=True):
    return subprocess.run(['tmux', '-S', socket, *args], text=True,
                          capture_output=True, check=check, timeout=10)


def pane():
    return tmux('capture-pane', '-p', '-S', '-300', '-t', 'smoke').stdout


def wait_for(predicate, label, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.25)
    raise AssertionError(label + '\n' + pane())


def send(text):
    tmux('send-keys', '-t', 'smoke', '-l', text)
    time.sleep(.3)
    tmux('send-keys', '-t', 'smoke', 'Enter')
    time.sleep(.5)


def key(text):
    tmux('send-keys', '-t', 'smoke', text)
    time.sleep(.4)


try:
    with tempfile.TemporaryDirectory(prefix='bone-plugin-pty-') as temp:
        root = Path(temp)
        cfg, project = root / 'config', root / 'project'
        cfg.mkdir()
        (cfg / 'init.lua').write_text('-- isolated plugin smoke config\n')
        project.mkdir()
        (project / '.git').touch()
        (cfg / 'providers.yaml').write_text(
            'version: 1\nactive: smoke\nproviders:\n  smoke:\n'
            '    label: Smoke\n    handler: openai\n    model: smoke\n'
            f'    base_url: http://127.0.0.1:{server.server_port}\n')

        env_prefix = f'BONE_DIR={shlex.quote(str(cfg))} BONE_CATALOG_URL={shlex.quote(str(catalog))}'

        # --- Phase A: seed legacy flat installs, then run the catalog UI. ---
        legacy = {
            'lua/tools/web_search.lua': 'plugins/web_search/init.lua',
            'lua/commands/memory.lua': 'plugins/memory/init.lua',
            'lua/tools/skill.lua': 'plugins/skill/init.lua',
            'lua/lib/skill.lua': 'plugins/skill/lib/skill.lua',
            'lua/commands/skill.lua': 'plugins/skill/commands/skill.lua',
            'lua/themes/nord.lua': 'plugins/themes/themes/nord.lua',
        }
        legacy_bytes = {}
        for dest, source in legacy.items():
            destination = cfg / dest
            destination.parent.mkdir(parents=True, exist_ok=True)
            data = (catalog / source).read_bytes()
            legacy_bytes[dest] = data
            destination.write_bytes(data)

        command = (f'cd {shlex.quote(str(project))} && {env_prefix} '
                   f'{shlex.quote(binary)} catalog; echo CAT_EXIT:$?; sleep 30')
        tmux('new-session', '-d', '-s', 'smoke', '-x', '140', '-y', '40', command)
        wait_for(lambda: 'Available' in pane(), 'catalog list did not render')

        # Select everything: legacy items become verbatim migrations, the rest
        # install fresh. Plugin installs/updates need an explicit consent 'y'.
        key('a')
        key('Enter')
        wait_for(lambda: 'Install plugin' in pane() and 'confirm' in pane(),
                 'consent prompt did not appear')
        key('y')
        wait_for(lambda: 'Done' in pane(), 'catalog apply did not finish')
        key('Enter')
        wait_for(lambda: 'CAT_EXIT:0' in pane(), 'catalog UI exited non-zero')

        plugins = cfg / 'lua' / 'plugins'
        for name in sorted(p.name for p in plugins.iterdir()):
            assert (plugins / name / 'init.lua').is_file(), f'{name}/init.lua missing'
        installed = {p.name for p in plugins.iterdir()}
        assert installed == {'ask_user', 'compact', 'cron', 'goal', 'history', 'mcp',
                             'memory', 'recap', 'review', 'shotgun', 'skill', 'subagent',
                             'task_loop', 'themes', 'usage', 'web_search'}, installed
        # Legacy files migrated byte-verbatim into the package layout.
        for dest, source in legacy.items():
            assert not (cfg / dest).exists(), f'legacy {dest} not swept'
        assert (plugins / 'web_search' / 'init.lua').read_bytes() == legacy_bytes['lua/tools/web_search.lua']
        assert (plugins / 'skill' / 'init.lua').read_bytes() == legacy_bytes['lua/tools/skill.lua']
        assert (plugins / 'skill' / 'lib' / 'skill.lua').read_bytes() == legacy_bytes['lua/lib/skill.lua']
        assert (plugins / 'skill' / 'commands' / 'skill.lua').read_bytes() == legacy_bytes['lua/commands/skill.lua']
        assert (plugins / 'themes' / 'themes' / 'nord.lua').read_bytes() == legacy_bytes['lua/themes/nord.lua']
        assert len(list((plugins / 'themes' / 'themes').glob('*.lua'))) == 11
        print('phase A passed: legacy migration + fresh plugin installs')

        # --- Phase B: main TUI — commands, plugin themes, tool registration. ---
        requests.clear()
        command = (f'cd {shlex.quote(str(project))} && {env_prefix} '
                   f'{shlex.quote(binary)}; echo SMOKE_EXIT:$?; sleep 30')
        tmux('new-window', '-t', 'smoke', '-n', 'tui', command)
        time.sleep(3)
        send('/skill')
        wait_for(lambda: 'No skills found.' in pane(), 'skill command did not run')
        send('/themes apply nord')
        wait_for(lambda: 'Theme applied: nord' in pane(), 'plugin-shipped theme did not apply')
        send('hello smoke')
        wait_for(lambda: 'SMOKE_RESPONSE' in pane(), 'response not rendered')
        assert requests, 'prompt did not reach the provider'
        advertised = tool_names(requests[-1])
        assert 'web_search' in advertised, advertised
        assert 'task_loop' in advertised, advertised
        key('C-c')
        time.sleep(.3)
        key('C-c')
        wait_for(lambda: 'SMOKE_EXIT:0' in pane(), 'unclean shutdown')
        print('phase B passed: /skill, plugin theme, tool advertisement, clean shutdown')

        # --- Phase C: plugins.disabled unregisters, re-enable restores. ---
        def prompt_advertises(tool):
            requests.clear()
            command = (f'cd {shlex.quote(str(project))} && {env_prefix} '
                       f'{shlex.quote(binary)}; echo SMOKE_EXIT:$?; sleep 30')
            tmux('new-window', '-t', 'smoke', '-n', f'tool-{tool}', command)
            time.sleep(3)
            send('check tool')
            wait_for(lambda: 'SMOKE_RESPONSE' in pane(), 'response not rendered')
            got = tool in tool_names(requests[-1]) if requests else False
            key('C-c')
            time.sleep(.3)
            key('C-c')
            wait_for(lambda: 'SMOKE_EXIT:0' in pane(), 'unclean shutdown')
            return got

        config = cfg / 'config.yaml'
        original = config.read_text()

        def disable_web_search(text):
            if '\nplugins:' not in '\n' + text:
                return text.rstrip() + '\nplugins:\n  disabled:\n    - web_search\n'
            lines = text.splitlines(True)
            for i, line in enumerate(lines):
                if line.rstrip() == 'plugins:':
                    lines.insert(i + 1, '  disabled:\n    - web_search\n')
                    break
            else:
                raise AssertionError('plugins: section not found in config.yaml')
            return ''.join(lines)

        try:
            config.write_text(disable_web_search(original))
            assert not prompt_advertises('web_search'), 'disabled plugin still advertised'
            config.write_text(original)
            assert prompt_advertises('web_search'), 're-enabled plugin not advertised'
        finally:
            config.write_text(original)
        print('phase C passed: plugins.disabled toggles registration')

    print('plugin PTY smoke passed')
finally:
    tmux('kill-server', check=False)
    server.shutdown()
