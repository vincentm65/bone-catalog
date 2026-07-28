import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createFakeDOM, FakeElement } from './firefox_dom_harness.mjs';

function install() {
  const nsSource = fs.readFileSync(new URL('../firefox_dom/extension/content/namespace.js', import.meta.url), 'utf8');
  const actionSource = fs.readFileSync(new URL('../firefox_dom/extension/content/dom-actions.js', import.meta.url), 'utf8');
  const context = { console, setTimeout, clearTimeout };
  vm.createContext(context);
  vm.runInContext(nsSource, context);
  vm.runInContext(actionSource, context);
  return context.FirefoxDOM;
}
function setup(tag = 'input', props = {}) {
  const dom = createFakeDOM();
  const node = dom.element(tag, props);
  dom.document.body.append(node);
  node.rect = { x: 10, y: 10, width: 100, height: 20, top: 10, left: 10, right: 110, bottom: 30 };
  node.focus = () => { dom.document.activeElement = node; };
  const map = new Map([['7:d3:0:n1', node]]);
  const ns = install();
  ns.register('core', {
    revision: 4,
    refFor: n => [...map.entries()].find(([, value]) => value === n)?.[0] || null,
    nodeFor: ref => map.get(typeof ref === 'string' ? ref : ref.ref),
    changesSince: since => ({ since, added: [], removed: [], updated: [] })
  });
  return { ...dom, node, ns, map };
}
function errorCode(promise) {
  return promise.then(() => null, error => error.code);
}

test('action module registers the act contract and validates refs/lifetime', async () => {
  const { ns, node, map } = setup();
  assert.equal(typeof ns.modules.actions.act, 'function');
  assert.equal(await errorCode(ns.modules.actions.act({ operation: 'focus', ref: 'bad' })), 'invalid_ref');
  node.remove();
  assert.equal(await errorCode(ns.modules.actions.act({ operation: 'focus', ref: '7:d3:0:n1' })), 'detached_node');
  map.delete('7:d3:0:n1');
  assert.equal(await errorCode(ns.modules.actions.act({ operation: 'focus', ref: '7:d3:0:n1' })), 'invalid_ref');
});

test('focus, click visibility and center covering checks report before/after state', async () => {
  const { ns, node, document } = setup('button');
  const seen = [];
  node.addEventListener('click', () => seen.push('click'));
  const focused = await ns.modules.actions.act({ operation: 'focus', ref: '7:d3:0:n1' });
  assert.equal(focused.focus.after.ref, '7:d3:0:n1');
  document.elementFromPoint = () => node;
  const clicked = await ns.modules.actions.act({ operation: 'click', ref: '7:d3:0:n1' });
  assert.deepEqual(seen, ['click']);
  assert.equal(clicked.result.clicked, true);
  const cover = new FakeElement('div', document);
  document.body.append(cover);
  document.elementFromPoint = () => cover;
  assert.equal(await errorCode(ns.modules.actions.act({ operation: 'click', ref: '7:d3:0:n1' })), 'covered_node');
});

test('type and set_value use property mutation and input/change ordering', async () => {
  const { ns, node } = setup('input', { type: 'text' });
  const events = [];
  for (const type of ['input', 'change']) node.addEventListener(type, () => events.push(type));
  const typed = await ns.modules.actions.act({ operation: 'type', ref: '7:d3:0:n1', text: 'ab' });
  assert.equal(node.value, 'ab');
  assert.equal(typed.result.typed, 2);
  await ns.modules.actions.act({ operation: 'set_value', ref: '7:d3:0:n1', value: 'done' });
  assert.deepEqual(events, ['input', 'input', 'input', 'change']);
});

test('type handles contenteditable text and Unicode characters', async () => {
  const { ns, node } = setup('div', { contenteditable: 'true' });
  const result = await ns.modules.actions.act({ operation: 'type', ref: '7:d3:0:n1', text: 'A😀' });
  assert.equal(node.textContent, 'A😀');
  assert.equal(result.result.typed, 2);
});

test('native select requires exactly one criterion and rejects ambiguous labels', async () => {
  const { ns, node } = setup('select');
  const a = new FakeElement('option', node.ownerDocument); a.textContent = 'Same'; a.value = 'a';
  const b = new FakeElement('option', node.ownerDocument); b.textContent = 'Same'; b.value = 'b';
  const c = new FakeElement('option', node.ownerDocument); c.textContent = 'Other'; c.value = 'c';
  node.append(a, b, c); node.options = [a, b, c];
  const events = []; node.addEventListener('input', () => events.push('input')); node.addEventListener('change', () => events.push('change'));
  assert.equal(await errorCode(ns.modules.actions.act({ operation: 'select', ref: '7:d3:0:n1', label: 'Same', value: 'a' })), 'invalid_request');
  assert.equal(await errorCode(ns.modules.actions.act({ operation: 'select', ref: '7:d3:0:n1', label: 'Same' })), 'ambiguous_match');
  const result = await ns.modules.actions.act({ operation: 'select', ref: '7:d3:0:n1', value: 'c' });
  assert.equal(result.result.index, 2);
  assert.deepEqual(events, ['input', 'change']);
});

test('canceled keydown suppresses manual defaults and exposes synthetic limitation', async () => {
  const { ns, node } = setup('input', { type: 'text' });
  node.addEventListener('keydown', event => event.preventDefault());
  const result = await ns.modules.actions.act({ operation: 'press', ref: '7:d3:0:n1', value: 'x' });
  assert.equal(node.value, '');
  assert.equal(result.result.default_applied, false);
  assert.match(result.synthetic_event_note, /untrusted/);
});

test('scroll, check, uncheck and submit are explicit operations with bounded changes', async () => {
  const { ns, node, document } = setup('input', { type: 'checkbox' });
  node.type = 'checkbox';
  let scrolled = false; node.scrollIntoView = () => { scrolled = true; };
  const checked = await ns.modules.actions.act({ operation: 'check', ref: '7:d3:0:n1', observe_changes: true });
  assert.equal(checked.result.checked, true);
  await ns.modules.actions.act({ operation: 'uncheck', ref: '7:d3:0:n1' });
  await ns.modules.actions.act({ operation: 'scroll_into_view', ref: '7:d3:0:n1' });
  assert.equal(scrolled, true);
  const form = setup('form');
  let submitted = 0; form.node.requestSubmit = () => { submitted += 1; };
  await form.ns.modules.actions.act({ operation: 'submit', ref: '7:d3:0:n1' });
  assert.equal(submitted, 1);
  assert.ok(document);
});
