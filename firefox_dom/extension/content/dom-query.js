/* Wave 1B: bounded, discovery-only DOM search. */
(function installFirefoxDOMQuery(root) {
  'use strict';

  var ns = root.FirefoxDOM;
  if (!ns) throw new Error('FirefoxDOM namespace is required');

  var BUDGET = ns.BUDGETS || { maxMatches: 100, maxDepth: 30, maxAttributeValue: 500 };
  var MAX_SELECTOR = 2000;
  var MAX_VISITS = 100000;

  function failure(code, message, details) {
    var e = new Error(message || code);
    e.code = code;
    if (details !== undefined) e.details = details;
    return e;
  }
  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  function first(a) { return a && a.length ? a[0] : null; }
  function asPredicates(request) {
    var p = request && request.predicates;
    p = p && typeof p === 'object' ? Object.assign({}, p) : {};
    [ 'tag', 'id', 'class', 'attribute', 'attributes', 'attr', 'text', 'direct_text', 'directText', 'descendant_text', 'descendantText',
      'accessible_name', 'accessibleName', 'role', 'visible', 'focused', 'focusable', 'enabled', 'editable',
      'selected', 'checked', 'ancestor', 'descendant', 'rect', 'rectangle' ].forEach(function (k) {
      if (own(request || {}, k)) p[k] = request[k];
    });
    if (p.attributes !== undefined && p.attribute === undefined) p.attribute = p.attributes;
    if (p.directText !== undefined && p.direct_text === undefined) p.direct_text = p.directText;
    if (p.descendantText !== undefined && p.descendant_text === undefined) p.descendant_text = p.descendantText;
    if (p.accessibleName !== undefined && p.accessible_name === undefined) p.accessible_name = p.accessibleName;
    return p;
  }
  function elementChildren(node) {
    if (!node) return [];
    if (node.children) return Array.prototype.slice.call(node.children);
    return Array.prototype.slice.call(node.childNodes || []).filter(function (n) { return n && n.nodeType === 1; });
  }
  function rootsFor(doc) {
    var roots = [], seen = [];
    function add(r) { if (r && seen.indexOf(r) < 0) { seen.push(r); roots.push(r); } }
    add(doc);
    function hosts(n) {
      elementChildren(n).forEach(function (c) {
        if (c.shadowRoot) { add(c.shadowRoot); hosts(c.shadowRoot); }
        hosts(c);
      });
    }
    if (doc && doc.documentElement) hosts(doc.documentElement);
    return roots;
  }
  function inert(node) { return !!node && /^(script|style)$/i.test(node.localName || node.tagName || ''); }
  function allElements(doc, core) {
    var out = [], seen = [], visits = 0;
    function visit(n) {
      if (!n || visits++ > MAX_VISITS || inert(n)) return;
      if (n.nodeType === 1 && seen.indexOf(n) < 0) { seen.push(n); out.push(n); }
      if (n.localName === 'slot' && typeof n.assignedNodes === 'function') {
        var assigned = n.assignedNodes({ flatten: true }) || n.assignedNodes();
        if (assigned.length) { Array.prototype.forEach.call(assigned, visit); return; }
      }
      elementChildren(n).forEach(visit);
      if (n.shadowRoot) visit(n.shadowRoot);
    }
    visit(doc && doc.documentElement ? doc.documentElement : doc);
    return out;
  }
  function selectorMatches(node, selector) {
    if (!selector) return true;
    if (typeof node.matches !== 'function') return false;
    try { return node.matches(selector); } catch (e) { throw failure('invalid_selector', 'Invalid CSS selector', { selector: selector }); }
  }
  function directText(node, core) {
    if (core && typeof core.directText === 'function') return core.directText(node);
    if (inert(node)) return '';
    var nodes = Array.prototype.slice.call(node && node.childNodes || []), textNodes = nodes.filter(function (n) { return n.nodeType === 3; });
    var text = textNodes.map(function (n) { return n.textContent || ''; }).join('');
    if (!textNodes.length && !nodes.some(function (n) { return n && n.nodeType === 1; })) text = node && node.textContent || '';
    return text.replace(/\s+/g, ' ').trim();
  }
  function descendantText(node) {
    if (!node || inert(node)) return '';
    if (node.nodeType === 3) return node.textContent || '';
    if (node.localName === 'slot' && typeof node.assignedNodes === 'function') {
      var assigned = node.assignedNodes({ flatten: true }) || node.assignedNodes();
      if (assigned.length) return Array.prototype.map.call(assigned, descendantText).join(' ');
    }
    var children = node.childNodes || [];
    var value = children.length ? Array.prototype.map.call(children, descendantText).join(' ') : node.textContent || '';
    return String(value).replace(/\s+/g, ' ').trim();
  }
  function bool(v) { return v === true || v === false ? v : !!v; }
  function style(node, name) { return node && node.ownerDocument && node.ownerDocument.defaultView && node.ownerDocument.defaultView.getComputedStyle ? node.ownerDocument.defaultView.getComputedStyle(node)[name] : (node.style && node.style[name]); }
  function rect(node) { return node && typeof node.getBoundingClientRect === 'function' ? node.getBoundingClientRect() : null; }
  function visible(node) {
    if (node.hidden || node.getAttribute && node.getAttribute('hidden') !== null) return false;
    var d = style(node, 'display'), v = style(node, 'visibility'), o = style(node, 'opacity');
    if (d === 'none' || v === 'hidden' || v === 'collapse' || o === '0') return false;
    var r = rect(node); return !r || (r.width > 0 && r.height > 0);
  }
  function focusable(node) {
    if (node.disabled || (node.hasAttribute && node.hasAttribute('disabled'))) return false;
    if (node.tabIndex >= 0 || (node.hasAttribute && node.hasAttribute('tabindex') && Number(node.getAttribute('tabindex')) >= 0)) return true;
    return /^(a|area|button|input|select|textarea|summary|iframe)$/.test(node.localName || '') && (node.localName !== 'a' || node.hasAttribute('href'));
  }
  function editable(node) {
    if (node.disabled || node.readOnly || node.hasAttribute && (node.hasAttribute('disabled') || node.hasAttribute('readonly'))) return false;
    if (node.localName === 'textarea') return true;
    if (node.localName === 'input') {
      var type = String(node.type || node.getAttribute && node.getAttribute('type') || 'text').toLowerCase();
      return !/^(button|checkbox|color|file|hidden|image|radio|range|reset|submit)$/.test(type);
    }
    return node.isContentEditable === true || node.getAttribute && node.getAttribute('contenteditable') === 'true';
  }
  function role(node) { return node.getAttribute && (node.getAttribute('role') || ({ button: 'button', a: 'link', input: 'textbox', select: 'combobox' }[node.localName] || '')); }
  function name(node) {
    var view = ns.modules && ns.modules.view;
    if (view && typeof view.accessibleName === 'function') return view.accessibleName(node);
    var n = node.getAttribute && (node.getAttribute('aria-label') || node.getAttribute('title') || node.getAttribute('alt'));
    if (n) return n.trim();
    var ids = node.getAttribute && node.getAttribute('aria-labelledby');
    if (ids && node.ownerDocument) return ids.split(/\s+/).map(function (id) { var x = node.ownerDocument.getElementById(id); return x ? descendantText(x) : ''; }).join(' ').trim();
    var labels = [];
    try { labels = Array.prototype.map.call(node.labels || [], descendantText).filter(Boolean); } catch (_) {}
    if (labels.length) return labels.join(' ');
    var placeholder = node.getAttribute && node.getAttribute('placeholder');
    if (placeholder) return placeholder.trim();
    return descendantText(node);
  }
  function textPredicate(value, actual) {
    if (typeof value === 'string') return actual.indexOf(value) >= 0;
    if (!value || typeof value !== 'object') return true;
    var expected = String(value.value !== undefined ? value.value : value.text || '');
    return value.exact ? actual === expected : actual.indexOf(expected) >= 0;
  }
  function attrPredicate(node, value) {
    if (!value) return true;
    var entries = Array.isArray(value) ? value : [value];
    return entries.every(function (a) {
      if (typeof a === 'string') return node.hasAttribute && node.hasAttribute(a);
      var key = a.name || a.attribute; if (!key) return true;
      if (!node.hasAttribute || !node.hasAttribute(key)) return false;
      return a.value === undefined || node.getAttribute(key) === String(a.value);
    });
  }
  function intersects(a, b) { return a && b && a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top; }
  function matchesPred(node, p, doc, all, core) {
    if (p.tag && String(node.localName || node.tagName).toLowerCase() !== String(p.tag).toLowerCase()) return false;
    if (p.id && node.id !== p.id) return false;
    if (p.class) { var classes = String(node.className || node.getAttribute && node.getAttribute('class') || '').split(/\s+/); if ((Array.isArray(p.class) ? p.class : [p.class]).some(function (c) { return classes.indexOf(c) < 0; })) return false; }
    if (!attrPredicate(node, p.attribute || p.attr)) return false;
    if (p.direct_text !== undefined && !textPredicate(p.direct_text, directText(node, core))) return false;
    if (p.descendant_text !== undefined && !textPredicate(p.descendant_text, descendantText(node))) return false;
    if (p.text !== undefined && !textPredicate(p.text, descendantText(node))) return false;
    if (p.role !== undefined && role(node) !== p.role) return false;
    if (p.accessible_name !== undefined && !textPredicate(p.accessible_name, name(node))) return false;
    var states = { visible: visible(node), focused: !!(doc && doc.activeElement === node), focusable: focusable(node), enabled: !node.disabled, editable: editable(node), selected: !!node.selected, checked: !!node.checked };
    for (var s in states) if (p[s] !== undefined && bool(p[s]) !== states[s]) return false;
    var rr = p.rect || p.rectangle; if (rr) { var r = rect(node); var box = rr.x !== undefined ? { left: rr.x, top: rr.y, right: rr.x + rr.width, bottom: rr.y + rr.height } : rr; if (!intersects(r, box)) return false; }
    if (p.ancestor && !all.some(function (x) { return x !== node && isAncestor(x, node, all) && matchesPred(x, p.ancestor, doc, all, core); })) return false;
    if (p.descendant && !all.some(function (x) { return x !== node && isAncestor(node, x, all) && matchesPred(x, p.descendant, doc, all, core); })) return false;
    return true;
  }
  function isAncestor(a, n, all) {
    for (var p = composedParent(n, all); p; p = composedParent(p, all)) if (p === a) return true;
    return false;
  }
  function composedParent(n, all) {
    if (!n) return null;
    if (n.assignedSlot) return n.assignedSlot;
    var parent = n.parentNode;
    if (parent && parent.host) return parent.host;
    if (all) {
      for (var i = 0; i < all.length; i++) {
        var candidate = all[i];
        if (candidate.localName === 'slot' && typeof candidate.assignedNodes === 'function') {
          var assigned = candidate.assignedNodes({ flatten: true }) || candidate.assignedNodes();
          if (Array.prototype.indexOf.call(assigned || [], n) >= 0) return candidate;
        }
      }
    }
    return parent;
  }
  function compact(node, core, view, input) {
    if (view && typeof view.describe === 'function') return view.describe(node, 'search', input);
    var out = { tag: String(node.localName || node.tagName || '').toLowerCase() };
    if (core && typeof core.refFor === 'function') out.ref = core.refFor(node);
    if (node.id) out.id = String(node.id).slice(0, 200);
    var c = node.getAttribute && node.getAttribute('class'); if (c) out.class = c.split(/\s+/).slice(0, 8);
    var t = directText(node, core); if (t) out.direct_text = t.slice(0, 300);
    var n = name(node); if (n) out.accessible_name = n.slice(0, 300);
    var r = rect(node); if (r) out.rect = { x: r.x, y: r.y, width: r.width, height: r.height };
    return Object.freeze(out);
  }
  function find(request, context) {
    request = request || {}; context = context || {};
    var core = context.core || ns.modules.core || {}, view = context.view || ns.modules.view || {};
    var doc = request.document || context.document || core.document || root.document;
    if (!doc) throw failure('invalid_request', 'A document is required for find');
    var css = request.css; if (css !== undefined && (typeof css !== 'string' || css.length > MAX_SELECTOR)) throw failure('invalid_selector', 'CSS selector is missing or exceeds the bound');
    var p = asPredicates(request), limit = Math.min(Math.max(0, Number(request.limit == null ? BUDGET.maxMatches : request.limit) || 0), BUDGET.maxMatches);
    if (css && typeof doc.querySelectorAll === 'function') {
      try { doc.querySelectorAll(css); } catch (e) { throw failure('invalid_selector', 'Invalid CSS selector', { selector: css }); }
    }
    var elements = allElements(doc, core), scope = request.within || p.within, withinNode = scope && typeof scope !== 'object' ? (core.nodeFor ? core.nodeFor(scope) : null) : scope;
    if (scope && !withinNode) throw failure('invalid_ref', 'within ref is not known');
    if (withinNode && core.isConnected && !core.isConnected(withinNode)) throw failure('detached_node', 'within ref is detached');
    if (withinNode) elements = elements.filter(function (n) { return n === withinNode || isAncestor(withinNode, n, elements); });
    var matches = [], truncated = false;
    for (var i = 0; i < elements.length; i++) {
      var n = elements[i];
      if (css && !selectorMatches(n, css)) continue;
      if (!matchesPred(n, p, doc, elements, core)) continue;
      if (matches.length >= limit) { truncated = true; break; }
      matches.push(compact(n, core, view));
    }
    return { matches: matches, count: matches.length, truncated: truncated || elements.length >= MAX_VISITS, omitted: truncated ? Math.max(1, elements.length - i) : 0, hint: truncated ? 'Narrow the selector, scope, or limit to continue.' : undefined };
  }

  ns.register('query', { find: find });
  if (typeof module !== 'undefined') module.exports = { find: find };
})(typeof globalThis !== 'undefined' ? globalThis : this);
