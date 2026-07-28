import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { createFakeDOM, FakeElement } from './firefox_dom_harness.mjs';

function loadQuery(core = {}) {
  let registered;
  const FirefoxDOM = {
    BUDGETS: { maxMatches: 100 },
    modules: { core, view: {} },
    register(name, api) { assert.equal(name, 'query'); registered = api; }
  };
  const source = readFileSync(new URL('../firefox_dom/extension/content/dom-query.js', import.meta.url), 'utf8');
  vm.runInNewContext(source, { globalThis: { FirefoxDOM }, FirefoxDOM, module: undefined });
  return registered;
}

function setup() {
  const dom = createFakeDOM();
  const core = { refFor: (node) => node._ref || (node._ref = `7:d3:0:n${Math.random()}`) };
  return { ...dom, query: loadQuery(core), core };
}

test('registers the FirefoxDOM query contract and finds structural elements', () => {
  const { element, document, query } = setup();
  const wrapper = element('section', { id: 'area' });
  const target = element('div', { class: 'clickable', tabindex: '0', textContent: 'Pay now' });
  wrapper.append(target); document.body.append(wrapper);
  const result = query.find({ document, css: '.clickable', predicates: { direct_text: { value: 'Pay now', exact: true }, focusable: true } });
  assert.equal(result.count, 1);
  assert.equal(result.matches[0].tag, 'div');
  assert.equal(result.matches[0].direct_text, 'Pay now');
});

test('searches open shadow roots without duplicate host matches', () => {
  const { element, document, query } = setup();
  const host = element('x-menu');
  const shadow = host.attachShadow();
  shadow.append(element('button', { class: 'option', textContent: 'One' }));
  document.body.append(host);
  const result = query.find({ document, css: '.option' });
  assert.equal(result.count, 1);
  assert.equal(result.matches[0].tag, 'button');
});

test('supports state, accessible-name, rectangle, ancestor and descendant predicates', () => {
  const { element, document, query } = setup();
  const region = element('div', { role: 'region' });
  const button = element('button', { 'aria-label': 'Submit', checked: true, rect: { left: 10, top: 10, right: 60, bottom: 40, width: 50, height: 30 } });
  region.append(button); document.body.append(region); document.activeElement = button;
  const result = query.find({ document, predicates: { accessible_name: { value: 'Submit', exact: true }, focused: true, checked: true, rect: { x: 0, y: 0, width: 100, height: 100 }, ancestor: { role: 'region' } } });
  assert.equal(result.count, 1);
});

test('editable state excludes readonly, disabled, and non-text controls', () => {
  const { element, document, query } = setup();
  const text = element('input', { type: 'text' });
  const readonly = element('input', { type: 'text' }); readonly.readOnly = true;
  const disabled = element('textarea'); disabled.disabled = true;
  const checkbox = element('input', { type: 'checkbox' });
  const select = element('select');
  document.body.append(text, readonly, disabled, checkbox, select);
  const result = query.find({ document, predicates: { editable: true } });
  assert.deepEqual(Array.from(result.matches, (match) => match.ref), [text._ref]);
});

test('searches native label and placeholder accessible names', () => {
  const { element, document, query } = setup();
  const label = element('label', { textContent: 'Account email' });
  const labelled = element('input', { type: 'email' }); labelled.labels = [label];
  const placeholder = element('input', { placeholder: 'Search orders' });
  document.body.append(label, labelled, placeholder);
  assert.equal(query.find({ document, predicates: { tag: 'input', accessible_name: { value: 'Account email', exact: true } } }).count, 1);
  assert.equal(query.find({ document, predicates: { tag: 'input', accessible_name: { value: 'Search orders', exact: true } } }).count, 1);
});

test('honors within scope and reports bounded truncation', () => {
  const { element, document, query } = setup();
  const scope = element('div');
  scope.append(element('span', { class: 'item' }), element('span', { class: 'item' }));
  document.body.append(scope, element('span', { class: 'item' }));
  const result = query.find({ document, css: '.item', within: scope, limit: 1 });
  assert.equal(result.count, 1);
  assert.equal(result.truncated, true);
  assert.match(result.hint, /Narrow/);
});

test('rejects an unknown within ref instead of widening to the whole document', () => {
  const { element, document, query } = setup();
  document.body.append(element('button', { textContent: 'Outside' }));
  assert.throws(
    () => query.find({ document, within: '7:d3:0:missing' }),
    (error) => error.code === 'invalid_ref'
  );
});

test('returns invalid_selector for browser-rejected CSS', () => {
  const { document, query } = setup();
  const bad = new FakeElement('div', document);
  bad.matches = () => { throw new SyntaxError('bad selector'); };
  document.body.append(bad);
  assert.throws(() => query.find({ document, css: '[' }), (error) => error.code === 'invalid_selector');
});

test('excludes script and style subtrees even when selectors or text predicates match', () => {
  const { element, document, query } = setup();
  document.body.append(element('script', { class: 'secret', textContent: 'token-value' }), element('style', { class: 'secret', textContent: '.secret{color:red}' }));
  const result = query.find({ document, css: '.secret', predicates: { text: 'token-value' } });
  assert.equal(result.count, 0);
});

test('uses composed slot ancestry without duplicating assigned nodes', () => {
  const { element, document, query } = setup();
  const host = element('x-panel'), light = element('span', { class: 'slotted', textContent: 'Choice' });
  host.append(light);
  const shadow = host.attachShadow(), slot = element('slot');
  slot.assignedNodes = () => [light]; shadow.append(slot); document.body.append(host);
  const result = query.find({ document, predicates: { ancestor: { tag: 'slot' }, direct_text: { value: 'Choice', exact: true } } });
  assert.equal(result.count, 1);
  assert.equal(result.matches[0].tag, 'span');
});

test('omits script and style descendants during text search', () => {
  const { element, document, query } = setup();
  const script = element('script');
  script.append(element('span', { class: 'secret', textContent: 'token-value' }));
  const style = element('style');
  style.append(element('span', { class: 'secret', textContent: 'token-value' }));
  document.body.append(script, style);
  assert.equal(query.find({ document, css: '.secret', predicates: { text: 'token-value' } }).count, 0);
});
