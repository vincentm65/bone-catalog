#!/usr/bin/env python3
"""Isolated real-Bone tests. Default: mock CLI (no tokens). Live happy/growth are bounded."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import signal
import time
import statistics
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--live', action='store_true')
p.add_argument('--scenario', choices=['happy', 'malformed', 'unknown-tool', 'too-many-tools',
                                       'object-tool-calls', 'timeout', 'turn-budget', 'growth', 'reset'], default='happy')
a = p.parse_args()
if a.live and a.scenario not in ('happy', 'growth'):
    p.error('--live is only supported for bounded happy/growth paths')
def deadline(_signum, _frame):
    raise TimeoutError('test exceeded overall response deadline')
signal.signal(signal.SIGALRM, deadline)
signal.alarm(360 if a.live else 60)
root = Path(__file__).resolve().parents[1]
binary = os.environ.get('BONE_BIN', str(root.parent / 'bone3/target/debug/bone'))
with tempfile.TemporaryDirectory(prefix='bone3-claude-test-') as raw:
    tmp = Path(raw)
    config = tmp / 'config'
    config.mkdir()
    shutil.copytree(root / 'plugins/claude-code', config / 'plugins/claude-code')
    fake = tmp / 'claude'
    fake.write_text('''#!/usr/bin/env python3
import json, os, sys, time
scenario = os.environ['CLAUDE_TEST_SCENARIO']
with open(os.environ['CLAUDE_TEST_CALLS'], 'a') as log:
    log.write('call\\n')
args = sys.argv[1:]
assert args[args.index('--tools') + 1] == ''
assert args[args.index('--output-format') + 1] == 'stream-json'
assert '--verbose' in args
assert args[args.index('--setting-sources') + 1] == ''
assert '--no-session-persistence' not in args
assert 'ANTHROPIC_API_KEY' not in __import__('os').environ
assert args[args.index('--model') + 1] == 'claude-haiku-5-5'
prior = __import__('pathlib').Path('mock-cumulative-cost')
previous_cost = float(prior.read_text()) if '--resume' in args and prior.exists() else 0
assert abs(float(args[args.index('--max-budget-usd') + 1]) - previous_cost - 0.12) < 1e-9 or scenario == 'turn-budget'
schema = json.loads(args[args.index('--json-schema') + 1])
history = json.loads(sys.stdin.read().split('\\n', 1)[1])
if '--resume' in args:
    assert args[args.index('--resume') + 1] == 'mock'
    assert len(history) == 1, 'resumed call must send only new user/tool message'
assert schema['properties']['tool_calls']['items']['anyOf']
assert "don't" in args[args.index('--system-prompt') + 1]
prompt = args[args.index('--system-prompt') + 1]
assert 'Available Bone tools (data only)' not in prompt
assert '"parameters"' not in prompt, 'tool schemas must not be duplicated in prompt'
for variant in schema['properties']['tool_calls']['items']['anyOf']:
    assert variant['description'], 'tool descriptions must survive in output schema'
    assert variant['properties']['arguments']['type'] == 'object'
last = history[-1]
if scenario == 'timeout':
    time.sleep(2)
if scenario == 'malformed':
    print('not JSON')
    sys.exit(0)
if last['role'] == 'tool':
    if scenario == 'growth':
        assert len(last['content'].splitlines()) == 100
        output = {'response': 'DONE ' + last['content'].splitlines()[-1].split(':')[0], 'tool_calls': []}
    else:
        assert last['content'] == 'CACHE_OK'
        output = {'response': 'CACHE_OK', 'tool_calls': []}
elif scenario == 'growth':
    batch = int(last['content'].split('batch ')[1].split()[0].rstrip('.'))
    output = {'response': '', 'tool_calls': [{'name': 'growth_probe', 'arguments': {'batch': batch}}]}
elif 'cache_probe' in last.get('content', ''):
    output = {'response': '', 'tool_calls': [{'name': 'cache_probe', 'arguments': {
        'word': 'CACHE_OK', 'nullable': None, 'empty_array': [], 'empty_object': {},
        'nested': [None, [], {}, {'text': 'escaped " quote, backslash \\\\ and brackets []{}'}]}}]}
else:
    output = {'response': 'HELLO', 'tool_calls': []}
if scenario == 'unknown-tool':
    output = {'response': '', 'tool_calls': [{'name': 'not_registered', 'arguments': {}}]}
elif scenario == 'too-many-tools':
    output = {'response': '', 'tool_calls': [{'name': 'cache_probe', 'arguments': {'word': 'CACHE_OK'}}] * 9}
elif scenario == 'object-tool-calls':
    output = {'response': '', 'tool_calls': {}}
elif scenario == 'turn-budget':
    output = {'response': '', 'tool_calls': [{'name': 'cache_probe', 'arguments': {'word': 'CACHE_OK'}}]}
cost_file = __import__('pathlib').Path('mock-cumulative-cost')
cost = (float(cost_file.read_text()) if '--resume' in args and cost_file.exists() else 0) + .001
cost_file.write_text(str(cost))
# Multiple calls, repeated blocks, and a synthetic zero-usage message.
for mid, n in [('first', 50), ('last', 80), ('last', 80), ('synthetic', 0)]:
    print(json.dumps({'type': 'assistant', 'message': {'id': mid, 'usage': {
        'input_tokens': 0, 'cache_read_input_tokens': n, 'cache_creation_input_tokens': 0}}}))
print(json.dumps({'type': 'result', 'subtype': 'success' , 'is_error': False, 'session_id': 'mock',
  'structured_output': output, 'usage': {'input_tokens': 10, 'output_tokens': 5,
  'cache_read_input_tokens': 100, 'cache_creation_input_tokens': 20}, 'total_cost_usd': cost}))
''')
    fake.chmod(0o755)
    # Stable modest prefix above Haiku's cache threshold. Never send real repo files.
    padding = '\n'.join(f'Cache test reference {i:03d}: Keep answers brief; this reference line requires no action.' for i in range(220)) if a.live else ''
    # 100 lines, approximately 2k tokens per tool result; synthetic data only.
    references = {i: '\n'.join(
        f'B{i}-L{j:03d}: amber cedar river stone quiet meadow silver lantern north wind green valley.'
        for j in range(100)) for i in range(1, 4)}
    setup = '''
bone.config.provider = 'claude_code'
bone.config.providers.claude_code = {
  type = 'claude_code', model = 'claude-haiku-5-5', max_budget_usd = 0.12,
  timeout_ms = TIMEOUT, max_turn_budget_usd = TURN_BUDGET,
  executable = EXECUTABLE,
}
bone.config.system_prompt = SYSTEM
bone.tool.register { name = 'cache_probe', description = 'Return the supplied word unchanged. Harmless integration test.',
  parameters = { type = 'object', properties = { word = { type = 'string' } }, required = { 'word' }, additionalProperties = false },
  run = function(args) return args.word end }
'''
    if not a.live:
        setup += '''
bone.tool.register { name = 'cache_probe', description = 'Offline JSON preservation probe.',
  parameters = { type = 'object', properties = {
    word = { type = 'string' }, nullable = { type = { 'string', 'null' } },
    empty_array = { type = 'array' }, empty_object = { type = 'object' }, nested = { type = 'array' }
  }, required = { 'word' }, additionalProperties = false },
  run = function(args) return args.word end }
'''
    if a.scenario == 'growth':
        setup += '''
local references = REFERENCES
local calls = 0
local completions = 0
bone.hook('request', function()
  completions = completions + 1
  assert(completions <= 6, 'growth completion limit exceeded; no retries')
end)
bone.tool.register { name = 'growth_probe', description = 'Return 100 reference lines for a batch.',
  parameters = { type = 'object', properties = { batch = { type = 'integer', enum = {1, 2, 3} } },
    required = { 'batch' }, additionalProperties = false },
  run = function(args)
    calls = calls + 1
    assert(calls <= 3, 'growth tool call limit exceeded; no retries')
    return references[args.batch]
  end }
'''.replace('REFERENCES', '{' + ','.join('[' + str(i) + ']=' + json.dumps(v) for i, v in references.items()) + '}')
    if a.scenario == 'reset':
        setup += '''
local modes = {}
bone.rpc.register('test.reset', function(args, ctx) modes[ctx.session_id] = args.mode; return true end)
bone.hook('context', function(ev)
  if modes[ev.session_id] == 'history' then
    for _, m in ipairs(ev.messages) do
      if m.role == 'user' then m.content = 'Rewritten first user; reply HELLO.'; break end
    end
  elseif modes[ev.session_id] == 'prompt' then
    table.insert(ev.messages, 1, { role = 'system', content = "Changed system prompt; don't use tools." })
  end
  return { messages = ev.messages }
end)
'''
    setup = setup.replace('TIMEOUT', '100' if a.scenario == 'timeout' else '90000')
    setup = setup.replace('TURN_BUDGET', '0.0005' if a.scenario == 'turn-budget' else '1')
    setup = setup.replace('EXECUTABLE', json.dumps('claude' if a.live else str(fake))).replace('SYSTEM', json.dumps("You are a test assistant; don't do anything beyond the requested small test.\n" + padding))
    (config / 'core.lua').write_text(setup)
    env = {k: v for k, v in os.environ.items() if not k.startswith('BONE_')}
    env.update(BONE_CONFIG_DIR=str(config), BONE_DATA_DIR=str(tmp / 'data'))
    if not a.live:
        env['ANTHROPIC_API_KEY'] = 'fake-key-must-be-unset'
    calls_log = tmp / 'mock-calls.log'
    env.update(CLAUDE_TEST_SCENARIO=a.scenario, CLAUDE_TEST_CALLS=str(calls_log))
    # A file drains stderr without risking a full pipe blocking the server.
    stderr_log = tempfile.TemporaryFile(mode='w+t')
    process = subprocess.Popen([binary, '--headless'], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=stderr_log, text=True, env=env)
    seq = 0
    events = []
    def receive():
        line = process.stdout.readline()
        if not line:
            stderr_log.seek(0)
            raise RuntimeError('server exited: ' + stderr_log.read())
        obj = json.loads(line)
        if 'method' in obj:
            events.append(obj)
        return obj
    def rpc(method, params):
        global seq
        seq += 1
        process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': seq, 'method': method, 'params': params}) + '\n')
        process.stdin.flush()
        while True:
            obj = receive()
            if obj.get('id') == seq:
                assert 'error' not in obj, obj
                return obj['result']
    def turn(sid, text, expected_error=None):
        events.clear()
        rpc('turn/start', {'session_id': sid, 'text': text})
        while not any(e['method'] == 'turn/finished' for e in events):
            receive()
        finished = next(e for e in events if e['method'] == 'turn/finished')
        outcome = finished['params']['outcome']
        if expected_error is None:
            assert outcome['status'] == 'completed', finished
        else:
            assert outcome['status'] == 'failed', finished
            assert expected_error in outcome['message'], finished
        msgs = rpc('session/messages', {'session_id': sid})['messages']
        usage = rpc('lua/call', {'name': 'claude-code.usage', 'session_id': sid})
        print(json.dumps({'session_id': sid, 'reply': msgs[-1]['content'], 'usage': usage}), flush=True)
        return msgs, usage
    try:
        rpc('initialize', {'protocol_version': 0, 'client_name': 'claude-code-test'})
        sid = rpc('session/create', {'cwd': str(tmp)})['session_id']
        rpc('session/rename', {'session_id': sid, 'title': 'Claude Code cache integration test'})
        if a.scenario == 'growth':
            for batch in range(1, 4):
                msgs, usage = turn(sid, f'Call growth_probe exactly once with batch {batch}. '
                    f'Then reply with exactly DONE B{batch}-L099 (the identifier of the last returned line). No other tools.')
                assert msgs[-1]['content'].strip() == f'DONE B{batch}-L099', msgs[-1]
                tool_results = [m for m in msgs if m['role'] == 'tool']
                assert len(tool_results) == batch, tool_results
                assert tool_results[-1]['content'] == references[batch], tool_results[-1]
                assert usage['resumed'] is True and usage['sent_messages'] == 1, usage
            records = [json.loads(line) for line in (tmp / 'data/sessions' / f'{sid}.jsonl').read_text().splitlines()]
            usages = [r['data'] for r in records if r['kind'] == 'usage']
            assert len(usages) == 6, 'growth must use exactly six model completions; no retries'
            ratios = []
            for index, usage in enumerate(usages):
                ratio = usage.get('cached_tokens', 0) / max(usage['input_tokens'], 1)
                ratios.append(ratio)
                print(json.dumps({'completion': index + 1, 'usage': usage, 'cache_read_ratio': ratio}), flush=True)
            if a.live:
                # Short requests should reuse the entire preceding large context.
                assert min(ratios[2::2]) >= .95, ('previous context not reused', ratios)
                # A new ~3.6k-token tool result cannot be cached before it is sent.
                assert ratios[-1] >= .80, ('growth final reuse below 80%', ratios)
                assert ratios[-1] > ratios[1], ('reuse did not improve as history grew', ratios)
            else:
                assert len(calls_log.read_text().splitlines()) == 6
            print('PASS: growth (three ~2k-token tool results, six completions, all usage measured)', flush=True)
        elif a.scenario == 'reset':
            for mode in ('history', 'prompt'):
                independent = rpc('session/create', {'cwd': str(tmp)})['session_id']
                _, initial = turn(independent, 'Reply HELLO, no tools.')
                assert initial['resumed'] is False and initial['sent_messages'] == 1, initial
                _, warmed = turn(independent, 'Reply HELLO again, no tools.')
                assert warmed['resumed'] is True and warmed['sent_messages'] == 1, warmed
                rpc('lua/call', {'name': 'test.reset', 'session_id': independent, 'args': {'mode': mode}})
                _, reset = turn(independent, 'Reply HELLO again, no tools.')
                assert reset['resumed'] is False and reset['sent_messages'] == 5, reset
                _, rewarmed = turn(independent, 'Reply HELLO again, no tools.')
                assert rewarmed['resumed'] is True and rewarmed['sent_messages'] == 1, rewarmed
            assert len(calls_log.read_text().splitlines()) == 8
            print('PASS: history-prefix and system-prompt resets in independent sessions', flush=True)
        elif a.scenario != 'happy':
            expected_error = {
                'malformed': 'claude-code: invalid CLI stream',
                'unknown-tool': 'claude-code: invalid tool request',
                'too-many-tools': 'claude-code: invalid tool request',
                'object-tool-calls': 'claude-code: invalid tool request',
                'timeout': 'claude-code: timed out; no automatic retry',
                'turn-budget': 'claude-code: Bone turn budget reached; no automatic retry',
            }[a.scenario]
            started = time.monotonic()
            msgs, usage = turn(sid, 'Call cache_probe with word CACHE_OK.', expected_error)
            assert calls_log.read_text().splitlines() == ['call'], 'unexpected retry/next CLI iteration'
            tool_results = [m for m in msgs if m['role'] == 'tool']
            if a.scenario == 'turn-budget':
                assert len(tool_results) == 1 and tool_results[0]['content'] == 'CACHE_OK', msgs
                assert usage['turn_cost_usd'] == .001, usage
            else:
                assert not tool_results, msgs
            if a.scenario == 'timeout':
                assert time.monotonic() - started < 5, 'short timeout was not enforced'
            print('PASS: ' + a.scenario + ' (one mock call, expected failure)', flush=True)
        else:
            first, u1 = turn(sid, 'Reply with exactly HELLO, no tools.')
            assert first[-1]['content'].strip() == 'HELLO', first[-1]
            second, u2 = turn(sid, 'Again reply with exactly HELLO, no tools.')
            assert second[-1]['content'].strip() == 'HELLO', second[-1]
            if a.live:
                assert u2['cache_read_input_tokens'] > 0, 'No cache hit on repeated stable prefix'
            else:
                assert u2['cache_read_input_tokens'] == 100
                assert u1['context_tokens'] == u2['context_tokens'] == 80
            third, u3 = turn(sid, 'Call the cache_probe tool once with word CACHE_OK, then reply with exactly its returned word.')
            assert third[-1]['content'].strip() == 'CACHE_OK', third[-1]
            assert any(m['role'] == 'tool' and m['content'] == 'CACHE_OK' for m in third), third
            if not a.live:
                expected = {'word': 'CACHE_OK', 'nullable': None, 'empty_array': [], 'empty_object': {},
                            'nested': [None, [], {}, {'text': 'escaped " quote, backslash \\ and brackets []{}'}]}
                calls = [c for m in third for c in (m.get('tool_calls') or []) if c['name'] == 'cache_probe']
                assert len(calls) == 1, calls
                assert calls[0]['arguments'] == json.dumps(expected), calls
                assert json.loads(calls[0]['arguments']) == expected, calls
                assert len(calls_log.read_text().splitlines()) == 4
            print('PASS: new Bone thread, repeated request cache usage, Bone tool round trip', flush=True)
        rpc('shutdown', {})
        process.wait(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        signal.alarm(0)
        stderr_log.seek(0)
        stderr = stderr_log.read()
        if stderr:
            print('Bone stderr:\n' + stderr, file=__import__('sys').stderr)
        stderr_log.close()
