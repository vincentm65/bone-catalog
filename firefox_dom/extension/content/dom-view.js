/* Wave 1C: bounded DOM projections. Depends only on the frozen FirefoxDOM/core contract. */
(function installView(root) {
  'use strict';
  var ns = root.FirefoxDOM;
  if (!ns) return;
  var B = ns.BUDGETS;
  var view = {};
  var SECRET = /(pass(word)?|token|secret|session|authorization|credential|api[_-]?key)/i;

  function core() { return ns.modules.core || {}; }
  function docOf(input) { return (input && (input.document || input.doc)) || root.document || null; }
  function elements(input) {
    var c = core(), result;
    try { result = typeof c.walk === 'function' ? c.walk(input && input.walkOptions) : null; } catch (_) { result = null; }
    if (Array.isArray(result)) return result.filter(function (n) { return n && (n.nodeType === 1 || n.localName); });
    var d = docOf(input), out = [];
    function visit(n) {
      if (!n) return;
      if (n.nodeType === 1 || n.localName) out.push(n);
      var kids = n.children || n.childNodes || [];
      for (var i = 0; i < kids.length; i++) if (kids[i].nodeType === 1) visit(kids[i]);
      if (n.shadowRoot) visit(n.shadowRoot);
    }
    if (d && d.documentElement) visit(d.documentElement);
    return out;
  }
  function ref(n) {
    var c = core();
    try { if (typeof c.refFor === 'function') return c.refFor(n); } catch (_) {}
    return n && (n.ref || n._ref || null);
  }
  function attr(n, name) { try { return n.getAttribute ? n.getAttribute(name) : (n.attributes && n.attributes.get ? n.attributes.get(name) : null); } catch (_) { return null; } }
  function has(n, name) { return attr(n, name) !== null || !!(n && n[name] === true); }
  function text(n) {
    var c = core(), value;
    try { if (typeof c.directText === 'function') value = c.directText(n); } catch (_) {}
    if (value == null) value = n && n.textContent || '';
    return String(value).replace(/\s+/g, ' ').trim();
  }
  function fullText(n) {
    if (!n || /^(script|style)$/i.test(n.localName || '')) return '';
    if (n.nodeType === 3) return String(n.textContent || '');
    var children = n.childNodes || [];
    var value = children.length ? Array.prototype.map.call(children, fullText).join(' ') : n.textContent || '';
    return String(value).replace(/\s+/g, ' ').trim();
  }
  function bounded(value, limit) { value = String(value == null ? '' : value); return value.length > limit ? value.slice(0, limit) : value; }
  function newTextBudget(value, fallback) {
    value = Number(value);
    var limit = Number.isFinite(value) && value >= 0 ? Math.floor(value) : fallback;
    return { remaining: Math.min(limit, B.totalText), omitted: 0 };
  }
  function budgetText(record, input) {
    var budget = input && input._textBudget;
    if (!budget) return record;
    ['direct_text', 'accessible_name', 'label'].forEach(function (field) {
      if (typeof record[field] !== 'string') return;
      if (record[field].length > budget.remaining) {
        budget.omitted += record[field].length - budget.remaining;
        record[field] = record[field].slice(0, budget.remaining);
        record.truncated = true;
      }
      budget.remaining -= record[field].length;
    });
    return record;
  }
  function redacted(n, value, field) {
    var c = core();
    try { if (typeof c.redact === 'function') { var r = c.redact(n, value, field); if (r !== undefined) return r; } } catch (_) {}
    var type = String(attr(n, 'type') || n.type || '').toLowerCase();
    var name = String(attr(n, 'name') || attr(n, 'id') || '');
    return (type === 'password' || type === 'hidden' || SECRET.test(name) || /url/i.test(field || '') && /@/.test(String(value))) ? '[REDACTED]' : value;
  }
  function rect(n, input) {
    var cache = input && input._layoutCache;
    if (cache && cache.rect.has(n)) return cache.rect.get(n);
    var result = null; try { var r = n.getBoundingClientRect && n.getBoundingClientRect(); if (r) result = { x: +r.x || +r.left || 0, y: +r.y || +r.top || 0, width: +r.width || 0, height: +r.height || 0, top: +r.top || 0, right: +r.right || 0, bottom: +r.bottom || 0, left: +r.left || 0 }; } catch (_) {}
    if (cache) cache.rect.set(n, result);
    return result;
  }
  function visible(n, r, input) {
    var cache = input && input._layoutCache;
    if (cache && cache.visible.has(n)) return cache.visible.get(n);
    if (n.hidden || attr(n, 'hidden') !== null) return false;
    var s = n.style || {}, cs = null;
    try { cs = n.ownerDocument && n.ownerDocument.defaultView && n.ownerDocument.defaultView.getComputedStyle ? n.ownerDocument.defaultView.getComputedStyle(n) : null; } catch (_) {}
    var display = (cs && cs.display) || s.display || '', visibility = (cs && cs.visibility) || s.visibility || '', opacity = (cs && cs.opacity) || s.opacity || '';
    var result = !(display === 'none' || visibility === 'hidden' || visibility === 'collapse' || opacity === '0') && (!r || (r.width > 0 && r.height > 0));
    if (cache) cache.visible.set(n, result);
    return result;
  }
  function editable(n) { var t = String(n.localName || '').toLowerCase(); return !n.readOnly && (/^(input|textarea)$/.test(t) || n.isContentEditable || n.contentEditable === true || attr(n, 'contenteditable') === 'true'); }
  function focusable(n) {
    if (n.disabled || has(n, 'disabled')) return false;
    var t = String(n.localName || '').toLowerCase(), ti = attr(n, 'tabindex');
    if (ti !== null) return Number(ti) >= 0;
    if ((t === 'a' || t === 'area') && attr(n, 'href') !== null) return true;
    return /^(button|input|select|textarea|summary|iframe)$/.test(t) || editable(n);
  }
  function labelledNodes(n) {
    var result = [], seen = [];
    function add(node) { if (node && seen.indexOf(node) < 0) { seen.push(node); result.push(node); } }
    try { Array.prototype.forEach.call(n.labels || [], add); } catch (_) {}
    var ids = attr(n, 'aria-labelledby'), rootNode = null, d = n && n.ownerDocument;
    try { rootNode = n.getRootNode && n.getRootNode(); } catch (_) {}
    if (ids) ids.split(/\s+/).forEach(function (id) {
      var node = rootNode && rootNode.getElementById ? rootNode.getElementById(id) : d && d.getElementById ? d.getElementById(id) : null;
      add(node);
    });
    return result;
  }
  function accessibleName(n) {
    var explicit = attr(n, 'aria-label');
    if (explicit) return explicit.replace(/\s+/g, ' ').trim();
    var labels = labelledNodes(n).map(fullText).filter(Boolean);
    if (labels.length) return labels.join(' ');
    for (var field of ['alt', 'placeholder', 'title']) {
      var value = attr(n, field);
      if (value) return value.replace(/\s+/g, ' ').trim();
    }
    return text(n);
  }
  function compactIdentity(out, n, tag) {
    ['id', 'name', 'type', 'for', 'tabindex'].forEach(function (name) {
      var value = attr(n, name);
      if (value !== null && value !== '') out[name] = bounded(value, B.maxAttributeValue);
    });
    var classes = attr(n, 'class');
    if (classes) out.class = classes.trim().split(/\s+/).filter(Boolean).slice(0, 8).map(function (value) { return bounded(value, 100); });
    ['placeholder', 'title'].forEach(function (name) {
      var value = attr(n, name);
      if (value) out[name] = bounded(value, B.maxAttributeValue);
    });
    var href = attr(n, 'href');
    if (href) out.href = bounded(redacted(n, href, 'href'), B.maxAttributeValue);
    if (/^(input|option)$/.test(tag) && (n.checked !== undefined || n.selected !== undefined)) {
      if (tag === 'input' && /^(checkbox|radio)$/i.test(attr(n, 'type') || n.type || '')) out.checked = !!n.checked;
      if (tag === 'option') out.selected = !!n.selected;
    }
  }
  function interactive(n) { var t = String(n.localName || '').toLowerCase(); return /^(a|button|input|select|textarea|option|summary)$/.test(t) || focusable(n) || typeof n.onclick === 'function' || attr(n, 'onclick') !== null || (n.style && n.style.cursor === 'pointer'); }
  function children(n) {
    var out = [], seen = [];
    function add(x) { if (x && x.nodeType === 1 && seen.indexOf(x) < 0) { seen.push(x); out.push(x); } }
    if (n && n.localName === 'slot' && typeof n.assignedNodes === 'function') {
      var assigned = n.assignedNodes({ flatten: true }) || n.assignedNodes();
      if (assigned.length) { Array.prototype.forEach.call(assigned, add); return out; }
    }
    var list = n && n.shadowRoot ? (n.shadowRoot.children || []) : (n && (n.children || n.childNodes) || []);
    for (var i = 0; i < list.length; i++) add(list[i]);
    return out;
  }
  function parent(n) { return n && (n.assignedSlot || n.parentElement || (n.parentNode && n.parentNode.nodeType === 1 ? n.parentNode : n.getRootNode && n.getRootNode().host)); }
  function important(n, descendants) {
    var tag = String(n.localName || '').toLowerCase(), t = text(n), role = attr(n, 'role');
    return !!(t || interactive(n) || /-/.test(tag) || role || attr(n, 'aria-label') || /^(form|dialog|table|ul|ol|li|nav|main|header|footer|section|article|aside|menu|label|details|summary|select|option)$/.test(tag) || descendants);
  }
  function scopeNodes(input, all) {
    var scope = input && input.scope || 'viewport', d = docOf(input), r = input && input.region;
    var rootNode = null;
    if (scope === 'subtree') {
      rootNode = getNode(input.ref, all);
      if (!rootNode) throw ns.error('invalid_ref', 'Subtree ref was not found');
    }
    else if (scope === 'focused') rootNode = d && d.activeElement;
    input._scopeRoot = rootNode;
    if (scope === 'document') return all;
    var box = scope === 'region' ? { x: +input.x || 0, y: +input.y || 0, right: (+input.x || 0) + (+input.width || 0), bottom: (+input.y || 0) + (+input.height || 0) } : null;
    return all.filter(function (n) {
      if (rootNode) return n === rootNode || contains(rootNode, n);
      var rr = rect(n, input);
      if (box) return !!(rr && !(rr.right < box.x || rr.x > box.right || rr.bottom < box.y || rr.y > box.bottom));
      if (scope === 'viewport') return !!(rr && visible(n, rr, input) && rr.right >= 0 && rr.x <= ((d && d.defaultView && d.defaultView.innerWidth) || 1024) && rr.bottom >= 0 && rr.y <= ((d && d.defaultView && d.defaultView.innerHeight) || 768));
      return false;
    });
  }
  function contains(a, b) { var n = b; while (n) { if (n === a) return true; n = parent(n); } return false; }
  function getNode(r, all) { for (var i = 0; i < all.length; i++) if (ref(all[i]) === r || all[i].ref === r) return all[i]; return null; }
  function base(n, level, input) {
    var r = rect(n, input), d = docOf(input), tag = String(n.localName || n.tagName || '').toLowerCase();
    var out = { ref: ref(n), tag: tag || 'unknown' }, direct = bounded(text(n), B.directText);
    compactIdentity(out, n, tag);
    var p = parent(n); if (p) out.parent = ref(p);
    if (direct) out.direct_text = direct;
    var role = attr(n, 'role'); if (role) out.role = role;
    var label = accessibleName(n); if (label && label !== direct) out.accessible_name = bounded(label, B.directText);
    if (r) {
      out.rect = r; out.visible = visible(n, r, input); out.in_viewport = !!(d && d.defaultView && r.right >= 0 && r.bottom >= 0 && r.left <= d.defaultView.innerWidth && r.top <= d.defaultView.innerHeight);
      var hit = null, hitRoot = d, treeRoot = null;
      try { treeRoot = n.getRootNode && n.getRootNode(); } catch (_) {}
      if (treeRoot && typeof treeRoot.elementFromPoint === 'function') hitRoot = treeRoot;
      try { hit = hitRoot && hitRoot.elementFromPoint ? hitRoot.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) : null; } catch (_) {}
      out.hit_test = { point: { x: r.left + r.width / 2, y: r.top + r.height / 2 }, hit: hit ? ref(hit) : null, covered: !!(hit && hit !== n && !contains(n, hit)), covered_by: hit && hit !== n && !contains(n, hit) ? ref(hit) : undefined };
    }
    out.focusable = focusable(n); out.focused = !!(d && d.activeElement === n); out.editable = editable(n); out.disabled = !!(n.disabled || has(n, 'disabled')); out.interaction = { native_control: /^(a|button|input|select|textarea|option)$/.test(tag), link: tag === 'a' && attr(n, 'href') !== null, inline_handler: typeof n.onclick === 'function' || attr(n, 'onclick') !== null, pointer_cursor: !!(n.style && n.style.cursor === 'pointer') };
    if (level === 'inspect') {
      var names = ['id','class','name','type','href','for','tabindex','placeholder','title','contenteditable','disabled','readonly','required']; out.attributes = {};
      for (var i = 0; i < names.length && Object.keys(out.attributes).length < B.maxAttributes; i++) { var v = attr(n, names[i]); if (v !== null) out.attributes[names[i]] = bounded(redacted(n, v, names[i]), B.maxAttributeValue); }
      for (var k = 0; n.attributes && k < n.attributes.length && Object.keys(out.attributes).length < B.maxAttributes; k++) { var a = n.attributes[k]; if (/^aria-/i.test(a.name)) out.attributes[a.name] = bounded(redacted(n, a.value, a.name), B.maxAttributeValue); }
      if ('value' in n) out.value = redacted(n, bounded(n.value, B.maxAttributeValue), 'value');
      ['checked','selected','indeterminate','open','disabled','readOnly','required'].forEach(function (key) { if (key in n && n[key] !== false && n[key] != null) out[key] = !!n[key]; });
      var childNodes = children(n);
      out.children = childNodes.slice(0, B.maxNodes).map(ref).filter(Boolean); out.child_count = childNodes.length;
      if (childNodes.length > out.children.length) { out.children_truncated = true; out.omitted_children = childNodes.length - out.children.length; }
    }
    return budgetText(out, input);
  }
  function metadata(omitted, hint, omittedText) {
    var truncated = omitted > 0 || omittedText > 0;
    var result = { truncated: truncated, omitted_nodes: omitted, continuation_hint: truncated ? hint : undefined };
    if (omittedText > 0) result.omitted_text = omittedText;
    return result;
  }
  view.describe = function (n, level, input) { return base(n, level === 'inspect' ? 'inspect' : 'outline', input || {}); };
  view.outline = function (input) {
    input = input || {}; input._layoutCache = { rect: new WeakMap(), visible: new WeakMap() }; input._textBudget = newTextBudget(input.max_text, B.outlineText); var all = elements(input), selected = scopeNodes(input, all), max = Math.min(Math.max(1, input.max_nodes || B.outlineNodes), B.maxNodes || 500), depth = Math.min(Math.max(0, input.depth == null ? 12 : input.depth), B.maxDepth), keep = new Set();
    selected.forEach(function (n) { var desc = children(n).some(function (c) { return important(c, false); }); if (important(n, desc)) { keep.add(n); var p = parent(n); while (p && selected.indexOf(p) >= 0) { keep.add(p); p = parent(p); } } });
    var records = [], omitted = 0; selected.forEach(function (n) { if (!keep.has(n)) return; var level = 0, p = n; while (p && p !== input._scopeRoot && (p = parent(p))) level++; if (level > depth) { omitted++; return; } if (records.length >= max) { omitted++; return; } var rec = base(n, 'outline', input); var kids = children(n).filter(function (c) { return keep.has(c); }); if (kids.length) rec.children = kids.map(ref).filter(Boolean); records.push(rec); });
    var result = { scope: input.scope || 'viewport', nodes: records }; Object.assign(result, metadata(omitted, 'Narrow scope, reduce depth, or inspect a subtree; continue with subtree ref.', input._textBudget.omitted)); return result;
  };
  view.inspect = function (input) {
    input = input || {}; input._layoutCache = { rect: new WeakMap(), visible: new WeakMap() }; input._textBudget = newTextBudget(input.max_text, B.inspectText); var all = elements(input), n = getNode(input.ref, all); if (!n) return { error: ns.error('invalid_ref', 'Node reference was not found') }; var result = { node: base(n, 'inspect', input), ancestors: [], relations: {}, siblings: [], descendants: [] }, include = input.include || ['ancestors','children'], max = Math.min(Math.max(1, Math.floor(input.max_nodes || 200)), B.maxNodes), depth = Math.min(Math.max(0, Math.floor(input.depth == null ? 2 : input.depth)), B.maxDepth), remaining = max - 1, omitted = 0, p = parent(n);
    function appendRecords(target, candidates, level) { var count = Math.min(remaining, candidates.length); for (var i = 0; i < count; i++) target.push(base(candidates[i], level, input)); remaining -= count; omitted += candidates.length - count; }
    if (include.indexOf('ancestors') >= 0) { var ancestors = []; while (p && ancestors.length < depth) { ancestors.push(p); p = parent(p); } appendRecords(result.ancestors, ancestors, 'outline'); }
    if (include.indexOf('siblings') >= 0 && parent(n)) appendRecords(result.siblings, children(parent(n)).filter(function (x) { return x !== n; }), 'outline');
    if (include.indexOf('children') >= 0) {
      var descendants = [], seen = new Set([n]);
      function collect(node, level) { if (level > depth) return; children(node).forEach(function (child) { if (seen.has(child)) return; seen.add(child); descendants.push(child); collect(child, level + 1); }); }
      collect(n, 1); appendRecords(result.descendants, descendants, 'inspect');
    }
    if (include.indexOf('options') >= 0 && String(n.localName).toLowerCase() === 'select') { result.options = children(n).slice(0, B.maxOptions).map(function (o) { return budgetText({ label: bounded(text(o), B.directText), value: redacted(o, o.value != null ? o.value : attr(o,'value'), 'option'), selected: !!o.selected, ref: ref(o) }, input); }); if (children(n).length > B.maxOptions) omitted += children(n).length - B.maxOptions; }
    if (include.indexOf('relations') >= 0) { ['aria-labelledby','aria-describedby','aria-controls','aria-owns','aria-activedescendant'].forEach(function (a) { var v = attr(n,a); if (v) { var relationName = { 'aria-labelledby': 'labelled_by', 'aria-describedby': 'described_by', 'aria-controls': 'controls', 'aria-owns': 'owns', 'aria-activedescendant': 'active_descendant' }[a]; result.relations[relationName] = v.split(/\s+/).map(function (id) { return getNodeById(id, n, all); }).filter(Boolean).map(ref); } }); var nativeLabels = labelledNodes(n).map(ref).filter(Boolean); if (nativeLabels.length) result.relations.labelled_by = Array.from(new Set((result.relations.labelled_by || []).concat(nativeLabels))); var f = attr(n,'for'); if (f) result.relations.label = getNodeById(f,n,all) && ref(getNodeById(f,n,all)); }
    Object.assign(result, metadata(omitted, 'Narrow include/depth or continue by inspecting a returned subtree ref.', input._textBudget.omitted)); return result;
  };
  function getNodeById(id, n, all) { for (var i=0;i<all.length;i++) if (attr(all[i],'id') === id) return all[i]; return null; }
  view.accessibleName = accessibleName;
  ns.register('view', view);
})(typeof globalThis !== 'undefined' ? globalThis : this);
