import test from 'node:test';
import assert from 'node:assert/strict';

const calls = [];
const listeners = { updated: new Set(), messages: new Set() };
const tabs = [{ id: 7, active: true, url: 'https://example.test/' }];
const browser = {
  tabs: {
    query: async () => tabs,
    get: async (id) => tabs.find((tab) => tab.id === id) || (() => { throw new Error('missing'); })(),
    update: async (id, change) => { calls.push(['update', id, change]); return { ...tabs[0], ...change }; },
    sendMessage: async (id, request, options) => {
      calls.push(['send', id, request, options]);
      if (options.frameId === 1) throw new Error('cross origin');
      return { ok: true, action: request.action, revision: 3, document_id: 'd3', result: {
        ref: 'n1', parent: null, children: ['n2'], hit_test: { hit: 'n3', covered_by: 'n4' },
        relations: { labelled_by: ['n5'], described_by: ['n6'], controls: ['n7'], owns: ['n8'], active_descendant: ['n9'], label: 'n10' }
      } };
    },
    onUpdated: { addListener: (fn) => listeners.updated.add(fn), removeListener: (fn) => listeners.updated.delete(fn) }
  },
  webNavigation: { getAllFrames: async () => [{ frameId: 0 }, { frameId: 1 }] },
  runtime: { onMessage: { addListener: (fn) => listeners.messages.add(fn) } }
};
globalThis.browser = browser;
const background = await import(`../firefox_dom/extension/background.js?test=${Date.now()}`);
const api = background.default || globalThis.FirefoxDOMBackground;

 test('external refs include tab, document, frame and local identity', () => {
  assert.deepEqual(api.parseRef('7:d3:0:n1'), { tab: '7', document: 'd3', frame: '0', local: 'n1', ref: '7:d3:0:n1' });
  assert.equal(api.makeRef(7, 'd3', 0, 'n1'), '7:d3:0:n1');
  assert.equal(api.parseRef('7:d3:n1'), null);
});

test('aggregate discovery preserves frame identity and reports inaccessible frames', async () => {
  calls.length = 0;
  const result = await api.dispatch({ action: 'find', tab_id: 7, css: '*', limit: 2 });
  assert.equal(result.ok, true);
  assert.equal(result.result.frames.length, 1);
  assert.equal(result.result.frames[0].frame_id, 0);
  assert.deepEqual(result.result.frames[0].result.ref, '7:d3:0:n1');
  assert.equal(result.result.frames[0].result.hit_test.hit, '7:d3:0:n3');
  assert.equal(result.result.frames[0].result.hit_test.covered_by, '7:d3:0:n4');
  assert.deepEqual(result.result.frames[0].result.relations, {
    labelled_by: ['7:d3:0:n5'], described_by: ['7:d3:0:n6'], controls: ['7:d3:0:n7'],
    owns: ['7:d3:0:n8'], active_descendant: ['7:d3:0:n9'], label: '7:d3:0:n10'
  });
  assert.deepEqual(result.result.inaccessible_frames, [{ frame_id: 1, error: { code: 'inaccessible_frame', message: 'frame is not accessible', details: { frame_id: 1 } } }]);
});

test('explicit refs preserve the external identity while targeting exactly its frame', async () => {
  calls.length = 0;
  const result = await api.dispatch({ action: 'inspect', tab_id: 7, ref: '7:d3:0:n1' });
  assert.equal(result.ok, true);
  assert.equal(calls.at(-1)[2].ref, '0:d3:0:n1');
  assert.equal(calls.at(-1)[3].frameId, 0);
});

test('frame_id filters non-ref requests and changes stays on one frame', async () => {
  calls.length = 0;
  const outline = await api.dispatch({ action: 'outline', tab_id: 7, frame_id: 0, max_nodes: 2 });
  assert.equal(outline.ok, true);
  assert.deepEqual(calls.filter((x) => x[0] === 'send').map((x) => x[3].frameId), [0]);
  const missing = await api.dispatch({ action: 'find', tab_id: 7, frame_id: 1, css: '*' });
  assert.equal(missing.ok, false);
  assert.equal(missing.error.code, 'inaccessible_frame');
  calls.length = 0;
  const changes = await api.dispatch({ action: 'changes', tab_id: 7, frame_id: 0, since_revision: 0 });
  assert.equal(changes.ok, true);
  assert.deepEqual(calls.filter((x) => x[0] === 'send').map((x) => x[3].frameId), [0]);
});

test('navigate recognizes the Firefox tabs.onUpdated callback and removes its listener', async () => {
  calls.length = 0;
  const navigating = api.dispatch({ action: 'navigate', tab_id: 7, url: 'https://example.test/next', timeout_ms: 1000 });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(listeners.updated.size, 1);
  for (const listener of listeners.updated) listener(7, { status: 'complete', url: 'https://example.test/next' }, tabs[0]);
  const result = await navigating;
  assert.equal(result.ok, true);
  assert.equal(result.revision, 3);
  assert.deepEqual(result.result, {
    tab_id: 7,
    url: 'https://example.test/next',
    frame_id: 0,
    document_id: 'd3'
  });
  assert.equal(calls.at(-1)[2].action, '_identity');
  assert.equal(listeners.updated.size, 0);
});

test('navigate removes its listener when Firefox rejects the URL', async () => {
  const update = browser.tabs.update;
  browser.tabs.update = async () => { throw new Error('rejected'); };
  try {
    const result = await api.dispatch({ action: 'navigate', tab_id: 7, url: 'bad:URL', timeout_ms: 1000 });
    assert.equal(result.ok, false);
    assert.equal(result.error.message, 'navigation failed');
    assert.equal(listeners.updated.size, 0);
  } finally {
    browser.tabs.update = update;
  }
});

test('navigate can return a bounded viewport outline with new-document refs', async () => {
  const sendMessage = browser.tabs.sendMessage;
  browser.tabs.sendMessage = async (id, request, options) => {
    calls.push(['send', id, request, options]);
    return {
      ok: true,
      action: request.action,
      revision: 5,
      document_id: 'new-document',
      result: { nodes: [{ ref: '0:new-document:0:n1', direct_text: 'Ready' }] }
    };
  };
  try {
    const navigating = api.dispatch({ action: 'navigate', tab_id: 7, url: 'https://example.test/outlined', outline: true });
    await new Promise((resolve) => setImmediate(resolve));
    for (const listener of listeners.updated) listener(7, { status: 'complete' }, tabs[0]);
    const result = await navigating;
    assert.equal(result.ok, true);
    assert.equal(result.revision, 5);
    assert.equal(result.result.document_id, 'new-document');
    assert.equal(result.result.outline.nodes[0].ref, '7:new-document:0:n1');
    assert.deepEqual(calls.at(-1)[2], {
      action: 'outline',
      scope: 'viewport',
      max_nodes: 150,
      max_text: 10000,
      depth: 12
    });
  } finally {
    browser.tabs.sendMessage = sendMessage;
  }
});

test('navigate retries the short content-script readiness race', async () => {
  const sendMessage = browser.tabs.sendMessage;
  let attempts = 0;
  browser.tabs.sendMessage = async (id, request, options) => {
    calls.push(['send', id, request, options]);
    attempts += 1;
    if (attempts === 1) throw new Error('content script not ready');
    return { ok: true, action: request.action, revision: 0, document_id: 'ready-document', result: { document_id: 'ready-document' } };
  };
  try {
    const navigating = api.dispatch({ action: 'navigate', tab_id: 7, url: 'https://example.test/race' });
    await new Promise((resolve) => setImmediate(resolve));
    for (const listener of listeners.updated) listener(7, { status: 'complete' }, tabs[0]);
    const result = await navigating;
    assert.equal(result.ok, true);
    assert.equal(result.result.document_id, 'ready-document');
    assert.equal(attempts, 2);
  } finally {
    browser.tabs.sendMessage = sendMessage;
  }
});

test('navigate preserves browser success when an optional outline fails', async () => {
  const sendMessage = browser.tabs.sendMessage;
  browser.tabs.sendMessage = async () => ({
    ok: false,
    action: 'outline',
    revision: 0,
    error: { code: 'invalid_request', message: 'outline failed' }
  });
  try {
    const navigating = api.dispatch({ action: 'navigate', tab_id: 7, url: 'https://example.test/no-outline', outline: true });
    await new Promise((resolve) => setImmediate(resolve));
    for (const listener of listeners.updated) listener(7, { status: 'complete' }, tabs[0]);
    const result = await navigating;
    assert.equal(result.ok, true);
    assert.equal(result.result.document_id, null);
    assert.equal(result.result.outline_error.code, 'invalid_request');
  } finally {
    browser.tabs.sendMessage = sendMessage;
  }
});

test('global node and text budgets are not multiplied across frames', async () => {
  browser.webNavigation.getAllFrames = async () => [{ frameId: 0 }, { frameId: 1 }, { frameId: 2 }];
  browser.tabs.sendMessage = async (id, request, options) => {
    calls.push(['send', id, request, options]);
    return { ok: true, action: request.action, revision: 3, document_id: 'd3', result: {
      scope: 'document', nodes: Array.from({ length: 100 }, (_, i) => ({ ref: `7:d3:${options.frameId}:n${i}`, direct_text: 'abcdefghij' }))
    } };
  };
  const result = await api.dispatch({ action: 'outline', tab_id: 7, scope: 'document', max_nodes: 150, max_text: 900 });
  const nodes = result.result.frames.flatMap((frame) => frame.result.nodes);
  assert.equal(result.ok, true);
  assert.equal(nodes.length, 150);
  assert.equal(result.result.omitted_nodes, 150);
  assert.equal(result.result.omitted_text, 2100);
  assert.equal(nodes.reduce((total, node) => total + (node.direct_text || '').length, 0), 900);
  assert.match(result.result.continuation_hint, /Narrow/);
});

test('global text budgets include accessible names', async () => {
  const oldFrames = browser.webNavigation.getAllFrames;
  const oldSendMessage = browser.tabs.sendMessage;
  browser.webNavigation.getAllFrames = async () => [{ frameId: 0 }];
  browser.tabs.sendMessage = async (id, request, options) => ({
    ok: true,
    action: request.action,
    revision: 3,
    document_id: 'd3',
    result: {
      matches: [{
        ref: `7:d3:${options.frameId}:n1`,
        direct_text: 'abc',
        accessible_name: 'wxyz'
      }]
    }
  });
  try {
    const result = await api.dispatch({ action: 'find', tab_id: 7, max_nodes: 10, max_text: 5 });
    const match = result.result.frames[0].result.matches[0];
    assert.equal(match.direct_text, 'abc');
    assert.equal(match.accessible_name, 'wx');
    assert.equal(match.truncated, true);
    assert.equal(result.result.omitted_text, 2);
    assert.equal(result.result.truncated, true);
  } finally {
    browser.webNavigation.getAllFrames = oldFrames;
    browser.tabs.sendMessage = oldSendMessage;
  }
});

test('cross-frame local refs are qualified on output and normalized for ref and within routing', async () => {
  const oldFrames = browser.webNavigation.getAllFrames;
  const oldSend = browser.tabs.sendMessage;
  const routed = [];
  browser.webNavigation.getAllFrames = async () => [{ frameId: 2, document_id: 'd3' }];
  browser.tabs.sendMessage = async (id, request, options) => {
    routed.push({ request, options });
    return { ok: true, action: request.action, revision: 4, document_id: 'd3', result: {
      ref: '0:d3:0:n1', parent: '0:d3:0:n2', nodes: [{ ref: '0:d3:0:n3' }], matches: [{ ref: '0:d3:0:n4' }]
    } };
  };
  try {
    const outline = await api.dispatch({ action: 'outline', tab_id: 7, frame_id: 2 });
    assert.equal(outline.result.frames[0].result.nodes[0].ref, '7:d3:2:n3');
    const found = await api.dispatch({ action: 'find', tab_id: 7, within: '7:d3:2:n1' });
    assert.equal(found.result.frames[0].result.matches[0].ref, '7:d3:2:n4');
    assert.equal(routed.at(-1).request.within, '0:d3:0:n1');
    const inspected = await api.dispatch({ action: 'inspect', tab_id: 7, ref: '7:d3:2:n1' });
    assert.equal(inspected.result.ref, '7:d3:2:n1');
    assert.equal(routed.at(-1).request.ref, '0:d3:0:n1');
    assert.equal(routed.at(-1).request.document_id, 'd3');
    assert.equal(routed.at(-1).options.frameId, 2);
    const acted = await api.dispatch({ action: 'act', tab_id: 7, ref: '7:d3:2:n1', operation: 'focus' });
    assert.equal(acted.result.ref, '7:d3:2:n1');
    assert.equal(routed.at(-1).request.ref, '0:d3:0:n1');
    assert.equal(routed.at(-1).options.frameId, 2);
    const conflict = await api.dispatch({ action: 'find', tab_id: 7, frame_id: 0, within: '7:d3:2:n1' });
    assert.equal(conflict.error.code, 'invalid_ref');
  } finally {
    browser.webNavigation.getAllFrames = oldFrames;
    browser.tabs.sendMessage = oldSend;
  }
});
test('mutations are serialized', async () => {
  let release;
  browser.tabs.sendMessage = async (id, request, options) => {
    calls.push(['send', id, request, options]);
    if (request.operation === 'first') await new Promise((resolve) => { release = resolve; });
    return { ok: true, action: request.action, revision: 1, result: {} };
  };
  const first = api.dispatch({ action: 'act', tab_id: 7, ref: '7:d3:0:n1', operation: 'first' });
  const second = api.dispatch({ action: 'act', tab_id: 7, ref: '7:d3:0:n1', operation: 'second' });
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(calls.filter((x) => x[2]?.operation === 'second').length, 0);
  release();
  await Promise.all([first, second]);
  assert.equal(calls.filter((x) => x[2]?.operation === 'second').length, 1);
});

test('preserves response_limit instead of reporting an oversized frame as inaccessible', async () => {
  const oldFrames = browser.webNavigation.getAllFrames;
  const oldSend = browser.tabs.sendMessage;
  browser.webNavigation.getAllFrames = async () => [{ frameId: 0 }];
  browser.tabs.sendMessage = async () => ({
    ok: true, action: 'find', revision: 3, document_id: 'd3',
    result: { ref: 'n1', payload: 'x'.repeat(5 * 1024 * 1024) }
  });
  try {
    const result = await api.dispatch({ action: 'find', tab_id: 7, css: '*' });
    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'response_limit');
  } finally {
    browser.webNavigation.getAllFrames = oldFrames;
    browser.tabs.sendMessage = oldSend;
  }
});
