#!/usr/bin/env python3
"""Real tmux PTY smoke for the ask_user catalog tool.

Drives the real `bone` TUI in a private tmux server with an isolated
temporary BONE_DIR and the catalog's ask_user tool installed. A single
ask_user call carrying a `questions` array with one multi_select question
and one text_input question is answered with actual tmux keystrokes
(Space toggles, Tab to custom input, typed text, Enter submits), with
pane captures at every stage, a mid-menu window resize, and a clean
shutdown check (SMOKE_EXIT:0).

Usage:
  python3 tests/ask_user_pty_smoke.py /path/to/bone --mode mock
  python3 tests/ask_user_pty_smoke.py /path/to/bone --mode llama \
      --llama-url http://127.0.0.1:8081

Modes:
  mock   Deterministic OpenAI-compatible provider that emits the ask_user
         tool call with fixed arguments; wire-level assertions on the
         advertised schema and the tool-result round trip.
  llama  Real local llama-server behind a logging proxy; wire-level
         assertions that the model itself emitted the questions-array
         tool call and that Bone returned the answers to it.

The smoke test installs the catalog tool unchanged and checks the schema
actually advertised to the provider.
"""
import argparse
import http.server
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

CATALOG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL_SOURCE = os.path.join(CATALOG, 'plugins', 'ask_user', 'init.lua')

Q1 = 'Which build features to include?'
Q2 = 'Notes for the release report?'
TOOL_ARGS = json.dumps({
    'questions': [
        {'question': Q1, 'type': 'multi_select',
         'options': ['Build', 'Test'], 'allow_custom': True, 'default': 1},
        {'question': Q2, 'type': 'text_input'},
    ],
}, separators=(',', ':'))
CUSTOM_TEXT = 'smoke-extra'
TEXT_ANSWER = 'tmux notes'

LLAMA_PROMPT = ('Ask me two questions together using ask_user: first, '
                '"Which build features to include?" Let me check any of Build '
                'and Test, in that order, and also type my own choice. '
                'Second, "Notes for the release report?" Let me type a free-text answer. '
                'After I answer both, reply with DONE and nothing else.')


class WireLog:
    """Shared request log: list of parsed request bodies."""

    def __init__(self):
        self.requests = []
        self.responses = []  # list of dicts: {'finish_reasons': [...], 'text': str}
        self.lock = threading.Lock()

    def add_request(self, body):
        with self.lock:
            self.requests.append(body)

    def add_response(self, record):
        with self.lock:
            self.responses.append(record)

    def find_ask_user_tool(self, body):
        for tool in body.get('tools') or []:
            if tool.get('function', {}).get('name') == 'ask_user':
                return tool['function']
        return None


# ---------------------------------------------------------------------------
# Deterministic mock provider
# ---------------------------------------------------------------------------

class MockProvider(http.server.BaseHTTPRequestHandler):
    wire = None

    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length))
        self.wire.add_request(body)
        is_first = len(self.wire.requests) == 1
        chunks = []
        if is_first:
            first, last = TOOL_ARGS[:-10], TOOL_ARGS[-10:]
            chunks.append({'delta': {'role': 'assistant', 'tool_calls': [{
                'index': 0, 'id': 'call_ask_smoke',
                'function': {'name': 'ask_user', 'arguments': first}}]}})
            chunks.append({'delta': {'tool_calls': [{
                'index': 0,
                'function': {'arguments': last}}]}})
            chunks.append({'delta': {}, 'finish_reason': 'tool_calls'})
        else:
            chunks.append({'delta': {'content': 'ASK_USER_DONE'}})
            chunks.append({'delta': {}, 'finish_reason': 'stop'})
        wire_response = {'finish_reasons': [], 'text': ''}
        lines = []
        for chunk in chunks:
            lines.append('data: ' + json.dumps({
                'id': 'smoke', 'object': 'chat.completion.chunk',
                'choices': [chunk]}))
            if chunk.get('finish_reason'):
                wire_response['finish_reasons'].append(chunk['finish_reason'])
            if chunk.get('delta', {}).get('content'):
                wire_response['text'] += chunk['delta']['content']
        wire_response['text'] += ''
        self.wire.add_response(wire_response)
        body_out = (''.join(l + '\n\n' for l in lines) + 'data: [DONE]\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body_out)))
        self.end_headers()
        self.wfile.write(body_out)


# ---------------------------------------------------------------------------
# Transparent logging proxy for the real llama-server
# ---------------------------------------------------------------------------

class LlamaProxy(http.server.BaseHTTPRequestHandler):
    wire = None
    upstream = ''

    def log_message(self, *_):
        pass

    def _sse_record(self, raw):
        record = {'finish_reasons': [], 'text': ''}
        for line in raw.decode('utf-8', 'replace').splitlines():
            if not line.startswith('data:'):
                continue
            data = line[5:].strip()
            if data == '[DONE]':
                continue
            try:
                value = json.loads(data)
            except ValueError:
                continue
            for choice in value.get('choices') or []:
                delta = choice.get('delta') or {}
                reason = choice.get('finish_reason')
                if reason:
                    record['finish_reasons'].append(reason)
                if delta.get('content'):
                    record['text'] += delta['content']
                for call in delta.get('tool_calls') or []:
                    fn = call.get('function') or {}
                    if fn.get('name'):
                        record.setdefault('tool_names', []).append(fn['name'])
                    if fn.get('arguments'):
                        record.setdefault('tool_arguments', '')
                        record['tool_arguments'] += fn['arguments']
        return record

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        self.wire.add_request(json.loads(body))
        upstream = self.upstream + self.path
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ('host', 'content-length', 'connection')}
        request = urllib.request.Request(upstream, data=body, headers=headers,
                                         method='POST')
        with urllib.request.urlopen(request, timeout=900) as response:
            self.send_response(response.status)
            for header in ('content-type',):
                if response.headers.get(header):
                    self.send_header(header, response.headers[header])
            self.end_headers()
            raw = b''
            while True:
                chunk = response.read(1024)
                if not chunk:
                    break
                raw += chunk
                self.wfile.write(chunk)
                self.wfile.flush()
        self.wire.add_response(self._sse_record(raw))


# ---------------------------------------------------------------------------
# tmux harness
# ---------------------------------------------------------------------------

class Tmux:
    def __init__(self, socket):
        self.socket = socket

    def run(self, *args, check=True):
        return subprocess.run(['tmux', '-S', self.socket, *args], text=True,
                              capture_output=True, check=check, timeout=10)

    def capture(self):
        return self.run('capture-pane', '-p', '-S', '-300', '-t', 'ask').stdout

    def key(self, keys):
        self.run('send-keys', '-t', 'ask', keys)
        time.sleep(0.45)

    def type_text(self, text):
        self.run('send-keys', '-t', 'ask', '-l', text)
        time.sleep(0.45)

    def resize(self, width, height):
        self.run('resize-window', '-t', 'ask', '-x', str(width), '-y', str(height))
        time.sleep(0.5)


def wait_for(harness, predicate, label, timeout, save=None):
    end = time.monotonic() + timeout
    last = ''
    while time.monotonic() < end:
        last = harness.capture()
        if predicate(last):
            return last
        time.sleep(0.25)
    if save:
        save(label + '.timeout', last)
    raise AssertionError(label + '\n--- last pane ---\n' + last)


def advertised_root_keys(wire):
    """Root property names advertised for ask_user in the first request."""
    for body in wire.requests:
        spec = wire.find_ask_user_tool(body)
        if spec:
            return sorted((spec.get('parameters') or {}).get('properties', {}))
    return []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('bone')
    parser.add_argument('--mode', choices=['mock', 'llama'], required=True)
    parser.add_argument('--llama-url', default='http://127.0.0.1:8081')
    parser.add_argument('--tool', default=None,
                        help='explicit ask_user.lua to install (default: catalog)')
    parser.add_argument('--artifacts', default=None)
    parser.add_argument('--menu-timeout', type=float, default=None)
    args = parser.parse_args()

    artifacts = args.artifacts or tempfile.mkdtemp(prefix='ask-user-pty-')
    os.makedirs(artifacts, exist_ok=True)
    summary = {'mode': args.mode, 'artifacts': artifacts, 'stages': []}

    # --- tool file -------------------------------------------------------
    tool_file = args.tool or TOOL_SOURCE
    summary['tool_file'] = tool_file
    summary['tool_note'] = 'catalog tool installed unchanged'

    def save(name, text):
        path = os.path.join(artifacts, name)
        with open(path, 'w') as handle:
            handle.write(text)
        summary['stages'].append(name)
        return path

    # --- isolated BONE_DIR ----------------------------------------------
    cfg = os.path.join(artifacts, 'bone-dir')
    project = os.path.join(artifacts, 'project')
    os.makedirs(os.path.join(cfg, 'lua', 'plugins', 'ask_user'))
    os.makedirs(project)
    open(os.path.join(project, '.git'), 'a').close()
    (open(os.path.join(cfg, 'init.lua'), 'w')
     .write('-- ask_user pty smoke config\n'))
    shutil.copyfile(tool_file, os.path.join(cfg, 'lua', 'plugins', 'ask_user', 'init.lua'))

    wire = WireLog()
    server = None
    if args.mode == 'mock':
        MockProvider.wire = wire
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MockProvider)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base_url = 'http://127.0.0.1:%d' % server.server_port
        prompt = 'Please ask me the release checklist questions.'
        menu_timeout = args.menu_timeout or 30
        final_marker = 'ASK_USER_DONE'
    else:
        LlamaProxy.wire = wire
        LlamaProxy.upstream = args.llama_url
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), LlamaProxy)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base_url = 'http://127.0.0.1:%d' % server.server_port
        prompt = LLAMA_PROMPT
        menu_timeout = args.menu_timeout or 420
        final_marker = None  # handled via wire + menu-gone check

    with open(os.path.join(cfg, 'providers.yaml'), 'w') as handle:
        handle.write(
            'version: 1\nactive: smoke\nproviders:\n  smoke:\n'
            '    label: Smoke\n    handler: openai\n    model: smoke\n'
            f'    base_url: {base_url}\n')

    socket = os.path.join(artifacts, 'tmux.sock')
    tmux = Tmux(socket)
    command = (f'cd {shlex.quote(project)} && '
               f'BONE_DIR={shlex.quote(cfg)} {shlex.quote(os.path.abspath(args.bone))}; '
               f'echo SMOKE_EXIT:$?; sleep 30')
    try:
        tmux.run('new-session', '-d', '-s', 'ask', '-x', '110', '-y', '35', command)
        time.sleep(3)
        save('stage-00-startup', tmux.capture())

        tmux.type_text(prompt)
        tmux.key('Enter')

        # --- Q1: multi_select -------------------------------------------
        pane = wait_for(
            tmux,
            lambda p: 'Question 1 of 2' in p and 'Build' in p
            and 'Test' in p and 'Space toggle' in p,
            'Q1 multi_select menu did not appear', menu_timeout, save)
        save('stage-01-q1-menu-110x35', pane)
        summary['q1_menu_110x35'] = True

        tmux.key('space')          # toggle "Build"
        pane = wait_for(tmux, lambda p: '[x] Build' in p,
                        'Build option did not check', 10, save)
        save('stage-02-q1-build-checked', pane)
        tmux.key('Down')
        tmux.key('space')          # toggle "Test"
        pane = wait_for(tmux, lambda p: '[x] Test' in p,
                        'Test option did not check', 10, save)
        save('stage-03-q1-both-checked', pane)

        # Mid-menu resize: menu must re-render at the new geometry.
        tmux.resize(80, 24)
        tmux.key('Tab')            # focus custom row; forces re-render at 80x24
        save('stage-04-q1-resized-80x24', tmux.capture())
        tmux.type_text(CUSTOM_TEXT)
        pane = wait_for(tmux, lambda p: 'Custom: ' + CUSTOM_TEXT in p,
                        'custom text did not appear', 10, save)
        save('stage-05-q1-custom-typed', pane)
        tmux.key('Enter')          # submit Q1 (values + custom)

        # --- Q2: text_input ----------------------------------------------
        pane = wait_for(tmux,
                        lambda p: 'Question 2 of 2' in p
                        and 'Enter submit' in p,
                        'Q2 text_input menu did not appear', 30, save)
        save('stage-06-q2-text-input', pane)
        tmux.type_text(TEXT_ANSWER)
        pane = wait_for(tmux, lambda p: TEXT_ANSWER in p,
                        'typed answer did not appear', 10, save)
        save('stage-07-q2-typed', pane)
        tmux.key('Enter')

        # --- review -------------------------------------------------------
        pane = wait_for(tmux,
                        lambda p: 'Review your answers.' in p
                        and 'Submit all answers' in p,
                        'review menu did not appear', 30, save)
        save('stage-08-review', pane)
        assert f'Q1: {Q1} → Build, Test, {CUSTOM_TEXT}' in pane, (
            'review did not summarize multi_select values+custom: ' + pane)
        assert f'Q2: {Q2} → {TEXT_ANSWER}' in pane, (
            'review did not summarize text answer: ' + pane)
        tmux.key('Enter')          # default selection is "✓ Submit all answers"

        # --- final response ----------------------------------------------
        if args.mode == 'mock':
            pane = wait_for(tmux, lambda p: final_marker in p,
                            'final mock response did not render', 30, save)
        else:
            def settled(p):
                return 'Submit all answers' not in p
            pane = wait_for(tmux, settled, 'menu did not clear after submit',
                            60, save)
            deadline = time.monotonic() + 420
            while time.monotonic() < deadline:
                if any('stop' in r.get('finish_reasons', [])
                       for r in wire.responses[1:]):
                    break
                time.sleep(0.5)
            else:
                raise AssertionError('llama final response did not finish')
            pane = tmux.capture()
        save('stage-09-final', pane)
        assert 'Submit all answers' not in pane, 'menu still visible after submit'
        assert 'SMOKE_EXIT' not in pane, 'TUI exited before final response'

        # Post-response resize: transcript must re-render cleanly.
        tmux.resize(110, 35)
        save('stage-10-resized-back-110x35', tmux.capture())

        # --- wire assertions ----------------------------------------------
        spec = wire.find_ask_user_tool(wire.requests[0]) if wire.requests else None
        assert spec, 'first provider request did not advertise ask_user'
        summary['advertised_root_keys'] = advertised_root_keys(wire)
        assert summary['advertised_root_keys'] == ['questions'], (
            'advertised root schema is not questions-only: '
            + str(summary['advertised_root_keys']))
        params = spec['parameters']
        assert params.get('additionalProperties') is False
        assert params.get('required') == ['questions']
        assert params['properties']['questions']['minItems'] == 1

        bodies = wire.requests
        assert len(bodies) >= 2, 'tool result was not sent back to the model'
        second = bodies[1]
        roles = [m.get('role') for m in second.get('messages', [])]
        assert 'assistant' in roles and 'tool' in roles, (
            'second request missing assistant/tool messages: ' + str(roles))
        assistant = next(m for m in second['messages']
                         if m.get('role') == 'assistant')
        calls = assistant.get('tool_calls') or []
        assert calls and calls[0].get('function', {}).get('name') == 'ask_user', (
            'assistant message did not carry the ask_user tool call')
        call_args = json.loads(calls[0]['function']['arguments'])
        assert call_args.get('questions'), 'tool call did not use a questions array'
        question_types = [q.get('type') for q in call_args['questions']]
        assert question_types == ['multi_select', 'text_input'], (
            'questions array does not match the smoke scenario: '
            + str(question_types))
        tool_msg = next(m for m in second['messages'] if m.get('role') == 'tool')
        assert tool_msg.get('tool_call_id'), 'tool result missing tool_call_id'
        # Bone may append a timing annotation after the JSON tool result.
        result, _ = json.JSONDecoder().raw_decode(tool_msg['content'].lstrip())
        assert result.get('cancelled') is False, 'tool result reports cancellation'
        answers = result['answers']
        assert len(answers) == 2, 'expected two answers: ' + str(answers)
        assert answers[0]['question'] == Q1
        assert answers[0]['values'] == ['Build', 'Test', CUSTOM_TEXT], (
            'multi_select values+custom mismatch: ' + str(answers[0]))
        assert answers[1]['question'] == Q2
        assert answers[1]['value'] == TEXT_ANSWER, (
            'text_input answer mismatch: ' + str(answers[1]))
        if args.mode == 'mock':
            assert wire.responses[0]['finish_reasons'] == ['tool_calls'], (
                'mock tool-call finish reason: '
                + str(wire.responses[0]['finish_reasons']))
            assert wire.responses[-1]['text'] == 'ASK_USER_DONE'
        else:
            final = wire.responses[-1]
            assert 'stop' in final.get('finish_reasons', []), (
                'llama final response did not finish cleanly: '
                + json.dumps(final))
            summary['llama_final_text'] = final.get('text', '')[:500]

        # --- clean shutdown -------------------------------------------------
        tmux.key('C-c')
        time.sleep(0.3)
        tmux.key('C-c')
        wait_for(tmux, lambda p: 'SMOKE_EXIT:0' in p, 'unclean shutdown', 20, save)
        save('stage-11-exit', tmux.capture())
        summary['shutdown'] = 'clean (SMOKE_EXIT:0)'
        summary['requests'] = len(bodies)
        summary['ok'] = True
        print('PASS %s: questions-only schema, multi_select+text_input in one '
              'call, keystrokes, resize, clean shutdown' % args.mode)
    except AssertionError as failure:
        summary['ok'] = False
        summary['failure'] = str(failure)
        print('FAIL %s: %s' % (args.mode, failure), file=sys.stderr)
    finally:
        tmux.run('kill-server', check=False)
        if server:
            server.shutdown()
        with open(os.path.join(artifacts, 'summary.json'), 'w') as handle:
            json.dump(summary, handle, indent=2)
        with open(os.path.join(artifacts, 'wire-requests.jsonl'), 'w') as handle:
            for body in wire.requests:
                handle.write(json.dumps(body) + '\n')
        with open(os.path.join(artifacts, 'wire-responses.json'), 'w') as handle:
            json.dump(wire.responses, handle, indent=2)
        print('artifacts: ' + artifacts)
    sys.exit(0 if summary.get('ok') else 1)


if __name__ == '__main__':
    main()
