/* Shared Wave 0 fake-DOM contract for Node tests. No browser or jsdom dependency. */

export const REQUESTS = Object.freeze({
  tabs: { action: 'tabs' },
  outline: { action: 'outline', tab_id: 7, scope: 'viewport', max_nodes: 150, max_text: 10000, depth: 12 },
  find: { action: 'find', css: '[role="button"]', visible: true, limit: 20 },
  inspect: { action: 'inspect', ref: '7:d3:0:n1', depth: 2, include: ['ancestors', 'children'], max_nodes: 200, max_text: 12000 },
  act: { action: 'act', ref: '7:d3:0:n1', operation: 'click', observe_changes: true, settle_ms: 300 },
  changes: { action: 'changes', tab_id: 7, frame_id: 0, since_revision: 1, max_nodes: 100, max_text: 6000 }
});

export function assertResponse(response, action) {
  if (!response || typeof response !== 'object' || typeof response.ok !== 'boolean') {
    throw new Error('response must have boolean ok');
  }
  if (response.action !== action || !Number.isInteger(response.revision) || response.revision < 0) {
    throw new Error('response action/revision contract failed');
  }
  if (response.ok) {
    if (!Object.prototype.hasOwnProperty.call(response, 'result') || response.error !== undefined) throw new Error('successful response shape failed');
  } else if (!response.error || typeof response.error.code !== 'string' || typeof response.error.message !== 'string') {
    throw new Error('error response shape failed');
  }
  return response;
}

class FakeEventTarget {
  constructor() { this.listeners = new Map(); }
  addEventListener(type, fn) { if (!this.listeners.has(type)) this.listeners.set(type, new Set()); this.listeners.get(type).add(fn); }
  removeEventListener(type, fn) { const set = this.listeners.get(type); if (set) set.delete(fn); }
  dispatchEvent(event) {
    event.target = event.target || this;
    event.currentTarget = this;
    const set = this.listeners.get(event.type) || [];
    for (const fn of [...set]) fn.call(this, event);
    return !event.defaultPrevented;
  }
}

export class FakeElement extends FakeEventTarget {
  constructor(tagName = 'div', ownerDocument = null) {
    super();
    this.nodeType = 1;
    this.tagName = String(tagName).toUpperCase();
    this.localName = String(tagName).toLowerCase();
    this.ownerDocument = ownerDocument;
    this.parentNode = null;
    this.childNodes = [];
    this.attributes = new Map();
    this.style = Object.create(null);
    this.shadowRoot = null;
    this.assignedNodes = () => [];
    this.value = '';
    this.checked = false;
    this.disabled = false;
    this.hidden = false;
    this.textContent = '';
    this.id = '';
  }
  append(...nodes) { for (let node of nodes) { if (typeof node === 'string') node = { nodeType: 3, textContent: node, parentNode: null, ownerDocument: this.ownerDocument, isConnected: false }; node.parentNode = this; node.ownerDocument = this.ownerDocument; this.childNodes.push(node); } return nodes[nodes.length - 1]; }
  remove() { if (this.parentNode) { const a = this.parentNode.childNodes; a.splice(a.indexOf(this), 1); this.parentNode = null; } }
  setAttribute(name, value) { name = String(name); value = String(value); this.attributes.set(name, value); if (name === 'id') this.id = value; }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  hasAttribute(name) { return this.attributes.has(name); }
  attachShadow() { this.shadowRoot = new FakeElement('#shadow-root', this.ownerDocument); this.shadowRoot.host = this; return this.shadowRoot; }
  get children() { return this.childNodes.filter((n) => n.nodeType === 1); }
  get isConnected() { return !!this.ownerDocument && (this === this.ownerDocument.documentElement || !!(this.parentNode && this.parentNode.isConnected)); }
  getBoundingClientRect() { return this.rect || { x: 0, y: 0, width: 100, height: 20, top: 0, left: 0, right: 100, bottom: 20 }; }
  matches(selector) {
    const tag = selector.match(/^[a-z][\w-]*/i); if (tag && this.localName !== tag[0].toLowerCase()) return false;
    const id = selector.match(/#([\w-]+)/); if (id && this.id !== id[1]) return false;
    const cls = selector.match(/\.([\w-]+)/); if (cls && !String(this.getAttribute('class') || '').split(/\s+/).includes(cls[1])) return false;
    const attr = selector.match(/\[([\w-]+)(?:=["']?([^\]"']+)["']?)?\]/); if (attr && (!this.hasAttribute(attr[1]) || (attr[2] && this.getAttribute(attr[1]) !== attr[2]))) return false;
    return !!(tag || id || cls || attr || selector === '*');
  }
  querySelectorAll(selector) { const out = []; const visit = (n) => { for (const child of n.children || []) { if (child.matches(selector)) out.push(child); visit(child); } }; visit(this); return out; }
}

export class FakeDocument extends FakeEventTarget {
  constructor() { super(); this.nodeType = 9; this.readyState = 'complete'; this.documentElement = new FakeElement('html', this); this.body = new FakeElement('body', this); this.documentElement.append(this.body); this.activeElement = this.body; this.defaultView = { document: this, innerWidth: 1024, innerHeight: 768 }; }
  createElement(tag) { return new FakeElement(tag, this); }
  querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector); }
  getElementById(id) { return this.querySelectorAll('#' + id)[0] || null; }
}

/* Returns {document, window, element(tag, props, ...children), disconnect}. */
export function createFakeDOM() {
  const document = new FakeDocument();
  const window = document.defaultView;
  const element = (tag, props = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (key === 'textContent' || key === 'rect') node[key] = value;
      else if (key in node) node[key] = value;
      else node.setAttribute(key, value);
    }
    node.append(...children);
    return node;
  };
  return { document, window, element, disconnect: () => { document.documentElement = null; } };
}

export const FAKE_DOM_CONTRACT = Object.freeze({
  element: 'FakeElement with nodeType/tagName/localName, parentNode/childNodes, attributes, ownerDocument, isConnected, shadowRoot, getBoundingClientRect()',
  tree: 'append establishes parentNode and ownerDocument; remove disconnects; document.body is connected',
  events: 'addEventListener/removeEventListener/dispatchEvent are deterministic and dispatch returns !defaultPrevented',
  shadow: 'attachShadow() creates an open shadow root; assignedNodes() is available for slot fixtures',
  browser: 'tests may pass document/window directly; harness never installs globals or emulates privileged Firefox APIs'
});
