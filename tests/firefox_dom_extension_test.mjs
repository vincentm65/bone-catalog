import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createFakeDOM } from './firefox_dom_harness.mjs';

const source = (name) => fs.readFileSync(new URL(`../firefox_dom/extension/content/${name}`, import.meta.url), 'utf8');

 test('manifest wires the coordinator after every content module and permits frame discovery', () => {
  const manifest = JSON.parse(fs.readFileSync(new URL('../firefox_dom/extension/manifest.json', import.meta.url), 'utf8'));
  assert.equal(manifest.browser_specific_settings.gecko.id, 'firefox-dom@bone.local');
  assert.ok(manifest.permissions.includes('webNavigation'));
  assert.deepEqual(manifest.content_scripts[0].js, [
    'content/namespace.js', 'content/dom-core.js', 'content/dom-query.js',
    'content/dom-view.js', 'content/dom-actions.js', 'content/content-main.js'
  ]);
  assert.equal(manifest.content_scripts[0].all_frames, true);
});

function install() {
  const dom = createFakeDOM();
  const context = { document: dom.document, console, Math, Set, Map, WeakMap, Promise, setTimeout, clearTimeout };
  context.globalThis = context;
  vm.createContext(context);
  for (const file of ['namespace.js', 'dom-core.js', 'dom-query.js', 'dom-view.js', 'dom-actions.js', 'content-main.js']) vm.runInContext(source(file), context);
  return { ...dom, ns: context.FirefoxDOM, handle: context.FirefoxDOM.modules.main.handle };
}
function connectedText(node, value) { node.append(value); return node; }
function localRef(ns, node) { return ns.modules.core.refFor(node); }

 test('content coordinator routes a custom dropdown mutation and newly exposed option', async () => {
  const { document, element, ns, handle } = install();
  const control = element('div', { role: 'button', tabindex: '0', 'aria-haspopup': 'listbox' }); connectedText(control, 'Choose account');
  document.body.append(control);
  const popup = element('div', { role: 'listbox', hidden: true });
  control.addEventListener('click', () => {
    popup.hidden = false;
    const option = element('div', { role: 'option', tabindex: '0' }); connectedText(option, 'Checking');
    popup.append(option);
    ns.modules.core.recordMutations([{ type: 'childList', target: popup, addedNodes: [option], removedNodes: [] }]);
  });
  document.body.append(popup);
  const outline = await handle({ action: 'outline', scope: 'document', max_nodes: 50 });
  assert.equal(outline.ok, true);
  const ref = localRef(ns, control);
  const acted = await handle({ action: 'act', ref, operation: 'click', observe_changes: true });
  assert.equal(acted.ok, true);
  assert.equal(acted.result.mutation_summary.changes.length, 2);
  const found = await handle({ action: 'find', predicates: { role: 'option', visible: true }, limit: 10 });
  assert.equal(found.ok, true);
  assert.equal(found.result.matches[0].direct_text, 'Checking');
});

test('routes native select, exact option criteria, ARIA relations, and open shadow slots', async () => {
  const { document, element, ns, handle } = install();
  const label = connectedText(element('label', { id: 'country-label' }), 'Country'); label.setAttribute('id', 'country-label');
  const select = element('select', { id: 'country', 'aria-labelledby': 'country-label' });
  const us = connectedText(element('option', { value: 'us', label: 'United States' }), 'United States'); us.selected = false;
  const ca = connectedText(element('option', { value: 'ca', label: 'Canada' }), 'Canada'); select.append(us, ca); select.options = [us, ca];
  document.body.append(label, select);
  const ref = localRef(ns, select);
  const inspection = await handle({ action: 'inspect', ref, include: ['relations', 'options'], depth: 2 });
  assert.deepEqual(Array.from(inspection.result.options, (o) => o.label), ['United States', 'Canada']);
  assert.equal(inspection.result.relations.labelled_by.length, 1);
  const selected = await handle({ action: 'act', ref, operation: 'select', value: 'ca' });
  assert.equal(selected.result.result.value, 'ca');
  assert.equal(ca.selected, true);

  const host = element('x-shell');
  const shadow = host.attachShadow();
  const slot = element('slot');
  const slotted = connectedText(element('button', { 'aria-label': 'Slotted action' }), 'Run');
  slot.assignedNodes = () => [slotted];
  host.append(slotted); shadow.append(slot); document.body.append(host);
  const found = await handle({ action: 'find', predicates: { accessible_name: { value: 'Slotted action', exact: true } } });
  assert.equal(found.result.count, 1);
  assert.equal(new Set(ns.modules.core.walk(document)).size, ns.modules.core.walk(document).length);
});

test('enforces stale/detached refs, redaction, visibility, coverage, and bounded outlines', async () => {
  const { document, element, ns, handle } = install();
  const secret = element('input', { type: 'password', name: 'password', value: 'never-return' });
  const hidden = element('input', { type: 'hidden', value: 'hidden-value' });
  const target = element('button', { tabindex: '0' }); connectedText(target, 'Target');
  document.body.append(secret, hidden, target);
  const inspected = await handle({ action: 'inspect', ref: localRef(ns, secret), include: [] });
  assert.equal(inspected.result.node.value, '[REDACTED]');
  document.elementFromPoint = () => element('div');
  assert.equal((await handle({ action: 'act', ref: localRef(ns, target), operation: 'click' })).error.code, 'covered_node');
  target.hidden = true;
  assert.equal((await handle({ action: 'act', ref: localRef(ns, target), operation: 'click' })).error.code, 'not_visible');
  target.hidden = false;
  const oldRef = localRef(ns, target); target.remove();
  assert.equal((await handle({ action: 'act', ref: oldRef, operation: 'focus' })).error.code, 'detached_node');
  assert.equal((await handle({ action: 'inspect', ref: '0:old-document:0:n1' })).error.code, 'invalid_ref');

  for (let i = 0; i < 40; i++) document.body.append(connectedText(element('button'), `Item ${i}`));
  const outline = await handle({ action: 'outline', scope: 'document', max_nodes: 5, max_text: 200 });
  assert.equal(outline.result.nodes.length, 5);
  assert.equal(outline.result.truncated, true);
  assert.match(outline.result.continuation_hint, /Narrow|subtree/);
});

test('changes expire deterministically and canceled keydown does not trigger manual default behavior', async () => {
  const { document, element, ns, handle } = install();
  const input = element('input', { type: 'text' }); input.focus = () => { document.activeElement = input; }; document.body.append(input);
  input.addEventListener('keydown', (event) => event.preventDefault());
  const result = await handle({ action: 'act', ref: localRef(ns, input), operation: 'press', value: 'x' });
  assert.equal(result.result.result.default_applied, false);
  for (let i = 0; i < 70; i++) ns.modules.core.recordMutations([{ type: 'attributes', target: input, attributeName: `data-${i}` }]);
  const expired = await handle({ action: 'changes', since_revision: 0 });
  assert.equal(expired.error.code, 'revision_expired');
});

test('content coordinator accepts top-level visible find predicates through the protocol boundary', async () => {
  const { document, element, ns, handle } = install();
  const visible = element('button', { textContent: 'Shown' });
  const hidden = element('button', { textContent: 'Hidden', hidden: true });
  document.body.append(visible, hidden);
  assert.ok(ns.PROTOCOL.request.includes('visible'));
  const found = await handle({ action: 'find', visible: true, limit: 10 });
  assert.equal(found.ok, true);
  assert.equal(found.result.matches.filter((match) => match.direct_text === 'Shown').length, 1);
  assert.equal(found.result.matches.some((match) => match.direct_text === 'Hidden'), false);
});

test('content coordinator rejects unknown fields and singular predicates at its boundary', async () => {
  const { handle } = install();
  const unknown = await handle({ action: 'outline', unexpected: true });
  assert.equal(unknown.error.code, 'invalid_request');
  const singular = await handle({ action: 'find', predicate: { role: 'button' } });
  assert.equal(singular.error.code, 'invalid_request');
  const unknownPredicate = await handle({ action: 'find', predicates: { role: 'button', typo: true } });
  assert.equal(unknownPredicate.error.code, 'invalid_request');
});

test('content boundary accepts normalized full local refs with its internal document identity', async () => {
  const { document, element, ns, handle } = install();
  const button = element('button', { id: 'local-target' }); connectedText(button, 'Target'); document.body.append(button);
  const ref = ns.modules.core.refFor(button);
  assert.match(ref, /^0:[^:]+:0:n\d+$/);
  const inspected = await handle({ action: 'inspect', ref, document_id: ns.modules.core.documentId, include: [] });
  assert.equal(inspected.ok, true);
  assert.equal(inspected.result.node.ref, ref);
  const found = await handle({ action: 'find', within: ref, document_id: ns.modules.core.documentId, limit: 10 });
  assert.equal(found.ok, true);
  assert.equal(found.result.matches.some((match) => match.ref === ref), true);
});
test('content coordinator rejects stale document requests at its boundary', async () => {
  const { ns, handle } = install();
  const stale = await handle({ action: 'outline', document_id: `${ns.modules.core.documentId}-old` });
  assert.equal(stale.error.code, 'stale_document');
  assert.equal(stale.action, 'outline');
});

test('content coordinator normalizes Error instances before extension messaging', async () => {
  const { ns, handle } = install();
  const missing = `0:${ns.modules.core.documentId}:0:missing`;
  const result = await handle({ action: 'find', within: missing, document_id: ns.modules.core.documentId });
  assert.equal(result.error.constructor.name, 'Object');
  assert.equal(result.error.code, 'invalid_ref');
  assert.equal(typeof result.error.message, 'string');
});

test('content coordinator exposes only its document identity to the internal probe', async () => {
  const { ns, handle } = install();
  const identity = await handle({ action: '_identity' });
  assert.equal(identity.ok, true);
  assert.deepEqual(
    JSON.parse(JSON.stringify(identity.result)),
    { document_id: ns.modules.core.documentId, frame_id: 0 }
  );
  assert.equal((await handle({ action: '_identity', max_nodes: 1 })).error.code, 'invalid_request');
});
