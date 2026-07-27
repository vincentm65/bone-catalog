import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createFakeDOM } from './firefox_dom_harness.mjs';

function loadCore(dom) {
  const context = { document: dom.document, console, Math, Set, Map, WeakMap };
  context.globalThis = context;
  vm.runInNewContext(fs.readFileSync(new URL('../firefox_dom/extension/content/namespace.js', import.meta.url), 'utf8'), context);
  vm.runInNewContext(fs.readFileSync(new URL('../firefox_dom/extension/content/dom-core.js', import.meta.url), 'utf8'), context);
  return context.FirefoxDOM;
}

test('registers the core contract and gives connected elements stable refs', () => {
  const dom = createFakeDOM();
  const firefoxDOM = loadCore(dom);
  const core = firefoxDOM.modules.core;
  const button = dom.element('button', { id: 'save' }, 'Save');
  dom.document.body.append(button);
  const first = core.refFor(button);
  assert.match(first, /^0:d[^:]+:0:n1$/);
  assert.equal(core.refFor(button), first);
  assert.equal(core.nodeFor(first), button);
  assert.equal(core.isConnected(button), true);
  assert.equal(core.documentId, first.split(':')[1]);
});

test('detached elements fail lookup and receive a new lifetime ref when reconnected', () => {
  const dom = createFakeDOM();
  const core = loadCore(dom).modules.core;
  const node = dom.element('div');
  dom.document.body.append(node);
  const oldRef = core.refFor(node);
  node.remove();
  assert.equal(core.isConnected(node), false);
  assert.equal(core.nodeFor(oldRef), node);
  dom.document.body.append(node);
  const newRef = core.refFor(node);
  assert.notEqual(newRef, oldRef);
  assert.equal(core.nodeFor(oldRef), node);
  assert.equal(core.nodeFor(newRef), node);
});

test('walks open shadow roots and flattened slots once, including nested roots', () => {
  const dom = createFakeDOM();
  const core = loadCore(dom).modules.core;
  const host = dom.element('x-card');
  const light = dom.element('span', {}, 'slotted');
  host.append(light);
  const shadow = host.attachShadow();
  const slot = dom.element('slot');
  slot.assignedNodes = () => [light];
  shadow.append(slot);
  const innerHost = dom.element('x-inner');
  const innerShadow = innerHost.attachShadow();
  innerShadow.append(dom.element('b', {}, 'inside'));
  shadow.append(innerHost);
  dom.document.body.append(host);
  const walked = core.walk(dom.document);
  assert.deepEqual(Array.from(walked, (n) => n.localName), ['html', 'body', 'x-card', 'slot', 'span', 'x-inner', 'b']);
  assert.equal(new Set(walked).size, walked.length);
});

test('extracts bounded direct text without repeating descendant text', () => {
  const dom = createFakeDOM();
  const core = loadCore(dom).modules.core;
  const outer = dom.element('div', {}, ' heading ', dom.element('span', {}, 'child text'));
  dom.document.body.append(outer);
  assert.equal(core.directText(outer), 'heading');
  assert.equal(core.directText(outer.children[0]), 'child text');
  assert.equal(core.directText(dom.element('script', {}, 'secret')), '');
  assert.equal(core.directText(dom.element('div', {}, 'x'.repeat(500))).length, 300);
});

test('coalesces mutation batches, bounds history, and expires old revisions', () => {
  const dom = createFakeDOM();
  const core = loadCore(dom).createCore({ document: dom.document, documentId: 'fixed', mutationHistory: 2, observe: false });
  const node = dom.element('div');
  dom.document.body.append(node);
  core.refFor(node);
  core.recordMutations([{ type: 'attributes', target: node, attributeName: 'class' }]);
  core.recordMutations([{ type: 'attributes', target: node, attributeName: 'id' }]);
  core.recordMutations([{ type: 'attributes', target: node, attributeName: 'title' }]);
  assert.equal(core.revision, 3);
  assert.deepEqual(Array.from(core.changesSince(1).changes[0].kinds), ['updated']);
  assert.equal(core.changesSince(0).expired, true);
  assert.equal(core.changesSince(3).changes.length, 0);
});

test('redaction uses the node identity even for non-sensitive output fields', () => {
  const dom = createFakeDOM();
  const core = loadCore(dom).modules.core;
  const secret = dom.element('input', { name: 'csrf_token', value: 'secret-value' });
  assert.equal(core.redact(secret, secret.value, 'value'), '[REDACTED]');
  const passwordNamed = dom.element('input', { value: 'another-secret' });
  passwordNamed.name = 'password';
  assert.equal(core.redact(passwordNamed, passwordNamed.value, 'value'), '[REDACTED]');
  assert.equal(core.redact(dom.element('input', { name: 'displayName' }), 'Alice', 'value'), 'Alice');
  for (const name of ['authToken', 'sessionId', 'apiKey']) {
    assert.equal(core.redact(dom.element('input', { name }), 'secret-value', 'value'), '[REDACTED]');
  }
  assert.equal(core.redact(dom.element('a'), 'https://example.test/path?next=home&count=2#ok', 'href'), 'https://example.test/path?next=home&count=2#ok');
  assert.equal(core.redact(dom.element('a'), 'https://user:pass@example.test/path?access_token=secret&session=private&auth=proof&key=value& ordinary=yes', 'href'), 'https://[REDACTED]@example.test/path?access_token=[REDACTED]&session=[REDACTED]&auth=[REDACTED]&key=[REDACTED]& ordinary=yes');
  for (const field of ['src', 'action', 'formaction']) {
    assert.equal(core.redact(dom.element('form'), `https://example.test/?apiKey=secret&safe=yes`, field), 'https://example.test/?apiKey=[REDACTED]&safe=yes');
  }
});

test('character data mutations are attributed to their owning element', () => {
  const dom = createFakeDOM();
  const core = dom.document && loadCore(dom).createCore({ document: dom.document, observe: false });
  const owner = dom.element('p');
  const text = { nodeType: 3, textContent: 'before', parentNode: owner, ownerDocument: dom.document };
  owner.append(text); dom.document.body.append(owner); core.refFor(owner);
  core.recordMutations([{ type: 'characterData', target: text }]);
  assert.equal(core.changesSince(0).changes[0].ref, core.refFor(owner));
  assert.equal(Array.from(core.changesSince(0).changes[0].kinds).join(','), 'updated');
});

test('detached tombstones and mutation batches remain bounded and report overflow', () => {
  const dom = createFakeDOM();
  const core = loadCore(dom).createCore({ document: dom.document, observe: false, tombstoneLimit: 1, mutationBatchLimit: 2 });
  const nodes = [dom.element('i'), dom.element('b'), dom.element('em')];
  const oldRefs = nodes.map((node) => { dom.document.body.append(node); const ref = core.refFor(node); node.remove(); core.isConnected(node); return ref; });
  nodes.forEach((node) => dom.document.body.append(node));
  const refs = nodes.map((node) => core.refFor(node));
  assert.equal(core.nodeFor(oldRefs[0]), null);
  assert.ok(core.nodeFor(oldRefs[2]) === nodes[2]);
  core.recordMutations(nodes.map((node) => ({ type: 'attributes', target: node })));
  assert.equal(core.changesSince(0).overflow, true);
  assert.equal(core.changesSince(0).fresh_outline, true);
});
