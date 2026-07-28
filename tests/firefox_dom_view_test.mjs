import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createFakeDOM } from './firefox_dom_harness.mjs';

function loadView() {
  const nsSource = fs.readFileSync(new URL('../firefox_dom/extension/content/namespace.js', import.meta.url), 'utf8');
  const viewSource = fs.readFileSync(new URL('../firefox_dom/extension/content/dom-view.js', import.meta.url), 'utf8');
  const dom = createFakeDOM();
  const refs = new Map();
  let serial = 0;
  const core = {
    documentId: 'd3', revision: 4,
    refFor(node) { if (!refs.has(node)) refs.set(node, `7:d3:0:n${++serial}`); return refs.get(node); },
    walk() {
      const out = [];
      const visit = (node) => { if (node?.nodeType === 1) out.push(node); for (const child of node?.children || []) visit(child); if (node?.shadowRoot) visit(node.shadowRoot); };
      visit(dom.document.documentElement);
      return out;
    },
    directText(node) { return node.textContent || ''; },
    redact(node, value) { return /password|token|secret/i.test(String(node?.type || node?.getAttribute?.('type') || node?.getAttribute?.('name') || '')) ? '[REDACTED]' : value; },
  };
  const context = { console, document: dom.document, FirefoxDOM: undefined };
  vm.createContext(context);
  vm.runInContext(nsSource, context);
  context.FirefoxDOM.register('core', core);
  vm.runInContext(viewSource, context);
  return { ...dom, ns: context.FirefoxDOM, core };
}

function byTag(result, tag) { return result.nodes.find((node) => node.tag === tag); }

test('outline prunes wrapper chains, retains context, and does not repeat ancestor text', () => {
  const { element, document, ns } = loadView();
  const outer = element('div', { textContent: 'Page title' });
  const wrapper = element('div', {});
  const button = element('div', { tabindex: '0', textContent: 'Continue' });
  wrapper.append(button); outer.append(wrapper); document.body.append(outer);
  const result = ns.modules.view.outline({ scope: 'document', max_nodes: 50, max_text: 1000, depth: 10, document });
  assert.equal(result.truncated, false);
  assert.ok(byTag(result, 'div'));
  const buttonRecord = result.nodes.find((n) => n.ref === ns.modules.core.refFor(button));
  assert.equal(buttonRecord.direct_text, 'Continue');
  assert.equal(result.nodes.filter((n) => n.direct_text === 'Page title').length, 1);
  assert.ok(result.nodes.some((n) => n.children?.includes(buttonRecord.ref)));
});

test('outline enforces node and text budgets with narrowing guidance', () => {
  const { element, document, ns } = loadView();
  for (let i = 0; i < 8; i++) document.body.append(element('button', { textContent: `Button ${i}` }));
  const result = ns.modules.view.outline({ scope: 'document', max_nodes: 3, max_text: 1000, document });
  assert.equal(result.nodes.length, 3);
  assert.equal(result.truncated, true);
  assert.equal(result.omitted_nodes, 7);
  assert.match(result.continuation_hint, /Narrow|subtree/);
});

test('inspect returns ancestors, siblings, relations, and bounded select options', () => {
  const { element, document, ns } = loadView();
  const form = element('form', { id: 'checkout' });
  const label = element('label', { textContent: 'Country' }); label.setAttribute('for', 'country');
  const select = element('select', { id: 'country', 'aria-describedby': 'help' }); select.setAttribute('id', 'country'); select.setAttribute('aria-describedby', 'help');
  const option = element('option', { value: 'us', textContent: 'United States' }); option.selected = true;
  select.append(option); const help = element('span', { textContent: 'Required' }); help.setAttribute('id', 'help');
  form.append(label, select, help); document.body.append(form);
  const result = ns.modules.view.inspect({ ref: ns.modules.core.refFor(select), include: ['ancestors', 'children', 'siblings', 'relations', 'options'], depth: 3, document });
  assert.equal(result.node.tag, 'select');
  assert.equal(result.options[0].label, 'United States');
  assert.equal(result.relations.described_by[0], ns.modules.core.refFor(help));
  assert.equal(result.ancestors[0].tag, 'form');
  assert.equal(result.siblings.length, 2);
});

test('geometry and interaction hints describe covered/visible context without leaking values', () => {
  const { element, document, ns } = loadView();
  const input = element('input', { type: 'password', name: 'password', value: 'do-not-return', rect: { x: 10, y: 10, width: 100, height: 20, top: 10, left: 10, right: 110, bottom: 30 } });
  const cover = element('div');
  document.body.append(input);
  document.elementFromPoint = () => cover;
  const result = ns.modules.view.inspect({ ref: ns.modules.core.refFor(input), include: [], document });
  assert.equal(result.node.rect.x, 10);
  assert.equal(result.node.rect.width, 100);
  assert.equal(result.node.interaction.native_control, true);
  assert.equal(result.node.editable, true);
  assert.equal(result.node.hit_test.covered, true);
  assert.equal(result.node.hit_test.covered_by, ns.modules.core.refFor(cover));
  assert.equal(result.node.value, '[REDACTED]');
});

test('region and subtree scopes stay narrow and use scope-relative depth', () => {
  const { element, document, ns } = loadView();
  const wrapper = element('div');
  const inside = element('button', { textContent: 'Inside', rect: { x: 10, y: 10, width: 30, height: 20, top: 10, left: 10, right: 40, bottom: 30 } });
  const outside = element('button', { textContent: 'Outside', rect: { x: 500, y: 500, width: 30, height: 20, top: 500, left: 500, right: 530, bottom: 520 } });
  wrapper.append(inside); document.body.append(wrapper, outside);
  const region = ns.modules.view.outline({ scope: 'region', x: 0, y: 0, width: 100, height: 100, document });
  assert.ok(region.nodes.some((node) => node.ref === ns.modules.core.refFor(inside)));
  assert.equal(region.nodes.some((node) => node.ref === ns.modules.core.refFor(outside)), false);
  const subtree = ns.modules.view.outline({ scope: 'subtree', ref: ns.modules.core.refFor(wrapper), depth: 1, document });
  assert.ok(subtree.nodes.some((node) => node.ref === ns.modules.core.refFor(inside)));
  assert.throws(
    () => ns.modules.view.outline({ scope: 'subtree', ref: '7:d3:0:missing', document }),
    (error) => error.code === 'invalid_ref'
  );
});

test('uses a fresh layout cache for each request', () => {
  const { element, document, ns } = loadView();
  const button = element('button', { textContent: 'Measure' });
  let reads = 0;
  button.getBoundingClientRect = () => { reads += 1; return { x: 0, y: 0, width: 20, height: 20, top: 0, left: 0, right: 20, bottom: 20 }; };
  document.body.append(button);
  ns.modules.view.outline({ scope: 'viewport', max_nodes: 50, document });
  assert.equal(reads, 1);
  const afterFirst = reads;
  ns.modules.view.inspect({ ref: ns.modules.core.refFor(button), include: [], document });
  assert.ok(reads > afterFirst);
});

test('uses composed shadow and slot children without duplicates', () => {
  const { element, document, ns } = loadView();
  const host = element('x-panel'), light = element('span', { textContent: 'Choice' });
  host.append(light);
  const shadow = host.attachShadow(), slot = element('slot');
  slot.assignedNodes = () => [light];
  shadow.append(slot); document.body.append(host);
  const hostResult = ns.modules.view.inspect({ ref: ns.modules.core.refFor(host), include: ['children'], document });
  assert.equal(hostResult.node.children.join(','), ns.modules.core.refFor(slot));
  const slotResult = ns.modules.view.inspect({ ref: ns.modules.core.refFor(slot), include: ['children'], document });
  assert.equal(slotResult.node.children.join(','), ns.modules.core.refFor(light));
  light.assignedSlot = slot;
  const lightResult = ns.modules.view.inspect({ ref: ns.modules.core.refFor(light), include: ['ancestors'], document });
  assert.equal(lightResult.ancestors[0].ref, ns.modules.core.refFor(slot));
});
