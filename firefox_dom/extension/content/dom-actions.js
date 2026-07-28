/* Wave 1D: explicit, serialized-by-background DOM mutations. */
(function installActions(root) {
  'use strict';
  var ns = root.FirefoxDOM;
  if (!ns) throw new Error('FirefoxDOM namespace is required');

  function fail(code, message, details) { throw ns.error(code, message, details); }
  function core() { return ns.modules.core || {}; }
  function docOf(node) { return node && node.ownerDocument; }
  function revision() {
    var c = core();
    return typeof c.revision === 'function' ? c.revision() : (Number.isInteger(c.revision) ? c.revision : 0);
  }
  function nodeRef(node) {
    var c = core();
    if (typeof c.refFor !== 'function') return null;
    return c.refFor(node);
  }
  function resolveNode(request, context) {
    var parsed = ns.parseRef(request.ref);
    if (!parsed) fail('invalid_ref', 'ref must be <tab>:<document>:<frame>:<local>');
    context = context || {};
    ['tab', 'document', 'frame'].forEach(function (part) {
      var expected = context[part + '_id'] != null ? context[part + '_id'] : context[part];
      if (expected != null && String(expected) !== parsed[part]) fail('stale_document', 'ref belongs to a different ' + part);
    });
    var c = core(), node = null;
    if (typeof c.nodeFor === 'function') {
      node = c.nodeFor(request.ref) || c.nodeFor(parsed.local) || c.nodeFor(parsed);
    }
    if (!node) fail('invalid_ref', 'node ref is not known');
    if (node.nodeType !== 1) fail('invalid_ref', 'ref does not identify an element');
    if (node.isConnected === false || (docOf(node) && docOf(node).documentElement === null)) fail('detached_node', 'node is detached');
    return node;
  }
  function style(node) {
    var d = docOf(node), w = d && d.defaultView;
    if (w && typeof w.getComputedStyle === 'function') return w.getComputedStyle(node);
    return node.style || {};
  }
  function visible(node) {
    if (!node || node.hidden || node.getAttribute && node.getAttribute('hidden') !== null) return false;
    var s = style(node);
    if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse' || s.opacity === '0') return false;
    var r = typeof node.getBoundingClientRect === 'function' ? node.getBoundingClientRect() : null;
    return !r || (r.width > 0 && r.height > 0);
  }
  function geometry(node) {
    var r = typeof node.getBoundingClientRect === 'function' ? node.getBoundingClientRect() : null;
    if (!r) return null;
    return { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom };
  }
  function hit(node) {
    var d = docOf(node), r = geometry(node), hitRoot = d, treeRoot = null;
    try { treeRoot = node.getRootNode && node.getRootNode(); } catch (_) {}
    if (treeRoot && typeof treeRoot.elementFromPoint === 'function') hitRoot = treeRoot;
    if (!hitRoot || !r || typeof hitRoot.elementFromPoint !== 'function') return null;
    var hitNode = hitRoot.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    if (!hitNode || hitNode === node || (typeof node.contains === 'function' && node.contains(hitNode))) return null;
    return hitNode;
  }
  function ensureInteractive(node, doHitTest) {
    if (!visible(node)) fail('not_visible', 'target is not visible', { synthetic_events: true });
    if (doHitTest) {
      var covering = hit(node);
      if (covering) fail('covered_node', 'target center is covered', { covering_ref: nodeRef(covering), synthetic_events: true });
    }
  }
  function focusState(doc) {
    var active = doc && doc.activeElement;
    return { focused: !!active, ref: active ? nodeRef(active) : null, tag: active && active.localName || null };
  }
  function event(type, init) {
    init = init || {};
    var C = root.Event;
    if (type.indexOf('key') === 0) C = root.KeyboardEvent || root.Event;
    try { return new C(type, Object.assign({ bubbles: true, cancelable: true, composed: true }, init)); }
    catch (_) { return Object.assign({ type: type, bubbles: true, cancelable: true, defaultPrevented: false, preventDefault: function () { this.defaultPrevented = true; } }, init); }
  }
  function send(node, type, init) { return node.dispatchEvent(event(type, init)); }
  function setNative(node, prop, value) {
    var proto = node && Object.getPrototypeOf(node), desc;
    while (proto && !desc) { desc = Object.getOwnPropertyDescriptor(proto, prop); proto = Object.getPrototypeOf(proto); }
    if (desc && desc.set) desc.set.call(node, value); else node[prop] = value;
  }
  function editable(node) {
    return /^(input|textarea|select)$/.test(node.localName) || node.isContentEditable || node.getAttribute && node.getAttribute('contenteditable') === 'true';
  }
  function editableValue(node) { return node.isContentEditable || node.getAttribute && node.getAttribute('contenteditable') === 'true' ? String(node.textContent || '') : String(node.value || ''); }
  function setEditableValue(node, value) {
    if (node.isContentEditable || node.getAttribute && node.getAttribute('contenteditable') === 'true') node.textContent = value;
    else setNative(node, 'value', value);
  }
  function appendEditableValue(node, value) {
    if ((node.isContentEditable || node.getAttribute && node.getAttribute('contenteditable') === 'true') && typeof node.insertAdjacentText === 'function') node.insertAdjacentText('beforeend', value);
    else setEditableValue(node, editableValue(node) + value);
  }
  function targetState(node) {
    var d = docOf(node), s = style(node);
    return { ref: nodeRef(node), tag: node.localName, value: redactValue(node), checked: node.checked === true, selected: node.selected === true, disabled: node.disabled === true, visible: visible(node), editable: !!editable(node), geometry: geometry(node), display: s.display || null, visibility: s.visibility || null, pointer_events: s.pointerEvents || s['pointer-events'] || null };
  }
  function redactValue(node) {
    if (node.type === 'password' || node.type === 'hidden') return null;
    var name = String(node.name || node.id || '').toLowerCase();
    if (/(token|secret|session|authorization|credential|password)/.test(name)) return null;
    return node.value === undefined ? null : String(node.value);
  }
  function options(node) { return Array.prototype.slice.call(node.options || node.children || []).filter(function (o) { return o && (o.localName === 'option' || String(o.tagName).toLowerCase() === 'option'); }); }
  function nativeSelect(node, request) {
    if (node.localName !== 'select') fail('unsupported_operation', 'select operation requires a native select');
    var keys = ['label', 'value', 'index'].filter(function (k) { return request[k] !== undefined; });
    if (keys.length !== 1) fail('invalid_request', 'select requires exactly one of label, value, or index');
    var os = options(node), matches;
    if (keys[0] === 'index') { if (!Number.isInteger(request.index) || request.index < 0 || request.index >= os.length) fail('no_match', 'option index is out of range'); matches = [os[request.index]]; }
    else matches = os.filter(function (o) {
      var actual = o[keys[0]];
      if (keys[0] === 'label' && actual === undefined) actual = o.textContent;
      return String(actual !== undefined ? actual : '').trim() === String(request[keys[0]]).trim();
    });
    if (!matches.length) fail('no_match', 'no option matches ' + keys[0]);
    if (matches.length > 1) fail('ambiguous_match', 'more than one option matches ' + keys[0], { count: matches.length });
    var chosen = matches[0];
    setNative(node, 'value', chosen.value);
    if (node.selectedIndex !== undefined) setNative(node, 'selectedIndex', os.indexOf(chosen));
    os.forEach(function (o) { if (o !== chosen) o.selected = false; o.selected = o === chosen; });
    send(node, 'input'); send(node, 'change');
    return { option: chosen.textContent != null ? String(chosen.textContent).trim() : chosen.value, value: String(chosen.value), index: os.indexOf(chosen) };
  }
  async function act(request, context) {
    if (!request || typeof request !== 'object' || typeof request.operation !== 'string') fail('invalid_request', 'act requires an operation and ref');
    if (ns.OPERATIONS.indexOf(request.operation) < 0) fail('unsupported_operation', 'unknown operation');
    var node = resolveNode(request, context), doc = docOf(node), beforeRevision = revision(), beforeFocus = focusState(doc), before = targetState(node), result = {};
    var op = request.operation;
    if (op === 'click') { ensureInteractive(node, true); if (typeof node.click === 'function') node.click(); else send(node, 'click'); result.clicked = true; }
    else if (op === 'focus') { if (!visible(node)) fail('not_visible', 'target is not visible', { synthetic_events: true }); if (typeof node.focus !== 'function') fail('unsupported_operation', 'target cannot be focused'); node.focus(); result.focused = true; }
    else if (op === 'type') { ensureInteractive(node, false); if (!editable(node)) fail('unsupported_operation', 'target is not editable'); if (typeof node.focus === 'function') node.focus(); var text = String(request.value == null ? request.text == null ? '' : request.text : request.value), characters = Array.from(text); for (var i = 0; i < characters.length; i++) { appendEditableValue(node, characters[i]); send(node, 'input', { data: characters[i], inputType: 'insertText' }); } result.typed = characters.length; }
    else if (op === 'set_value') { ensureInteractive(node, false); if (!editable(node)) fail('unsupported_operation', 'target is not editable'); setEditableValue(node, String(request.value == null ? request.text == null ? '' : request.text : request.value)); send(node, 'input'); send(node, 'change'); result.value = redactValue(node); }
    else if (op === 'select') { ensureInteractive(node, false); result = nativeSelect(node, request); }
    else if (op === 'press') { ensureInteractive(node, false); if (typeof node.focus === 'function') node.focus(); var key = String(request.value == null ? request.key || '' : request.value); if (!key) fail('invalid_request', 'press requires key'); var down = event('keydown', { key: key, code: request.code || key }); var allowed = node.dispatchEvent(down); if (allowed && !down.defaultPrevented && editable(node) && key.length === 1) { appendEditableValue(node, key); send(node, 'input', { data: key, inputType: 'insertText' }); } if (allowed && !down.defaultPrevented && key === 'Enter' && node.form && typeof node.form.requestSubmit === 'function') node.form.requestSubmit(); send(node, 'keyup', { key: key, code: request.code || key }); result.key = key; result.default_applied = !!(allowed && !down.defaultPrevented); }
    else if (op === 'scroll_into_view') { if (typeof node.scrollIntoView !== 'function') fail('unsupported_operation', 'target cannot scroll'); node.scrollIntoView({ block: request.block || 'center', inline: request.inline || 'nearest', behavior: 'auto' }); result.scrolled = true; }
    else if (op === 'scroll') { if (typeof node.scrollBy === 'function') node.scrollBy(Number(request.x || 0), Number(request.y || 0)); else if (doc.defaultView && typeof doc.defaultView.scrollBy === 'function') doc.defaultView.scrollBy(Number(request.x || 0), Number(request.y || 0)); else fail('unsupported_operation', 'target cannot scroll'); result.scrolled = true; }
    else if (op === 'check' || op === 'uncheck') { ensureInteractive(node, true); if (node.localName !== 'input' || node.type !== 'checkbox') fail('unsupported_operation', 'check requires a checkbox'); if (node.disabled) fail('unsupported_operation', 'disabled checkbox cannot be changed'); var checked = op === 'check'; setNative(node, 'checked', checked); send(node, 'input'); send(node, 'change'); result.checked = checked; }
    else if (op === 'submit') { ensureInteractive(node, true); var form = node.localName === 'form' ? node : node.form; if (!form) fail('unsupported_operation', 'target has no form'); var accepted = true; if (typeof form.requestSubmit === 'function') form.requestSubmit(); else accepted = send(form, 'submit'); result.submitted = accepted; }
    var settle = Math.max(0, Math.min(2000, Number(request.settle_ms || 0)));
    if (settle) await new Promise(function (resolve) { setTimeout(resolve, settle); });
    var afterFocus = focusState(doc), after = targetState(node), summary;
    if (request.observe_changes && typeof core().changesSince === 'function') summary = core().changesSince(beforeRevision, { max_nodes: 100, max_text: 6000 });
    return { target: { before: before, after: after }, focus: { before: beforeFocus, after: afterFocus }, result: result, synthetic_events: true, synthetic_event_note: 'Events dispatched by a WebExtension are untrusted; page default behavior may differ from physical input.', mutation_summary: summary === undefined ? null : summary };
  }
  ns.register('actions', { act: act, validate: resolveNode });
})(typeof globalThis !== 'undefined' ? globalThis : this);
