/* Wave 2 content coordinator. DOM work is delegated to the loaded modules. */
(function installContentMain(root) {
  'use strict';
  var ns = root.FirefoxDOM;
  if (!ns) throw new Error('FirefoxDOM namespace is required');
  var core = ns.modules.core;
  var query = ns.modules.query;
  var view = ns.modules.view;
  var actions = ns.modules.actions;
  var allowed = Object.create(null);
  ns.PROTOCOL.request.forEach(function (name) { allowed[name] = true; });
  ['x', 'y', 'width', 'height', 'key', 'code', 'block', 'inline', 'maxNodes', 'maxText'].forEach(function (name) { allowed[name] = true; });

  var predicateFields = {
    tag: true, id: true, 'class': true, attribute: true, attributes: true, attr: true,
    text: true, direct_text: true, directText: true, descendant_text: true, descendantText: true,
    accessible_name: true, accessibleName: true, role: true, visible: true, focused: true,
    focusable: true, enabled: true, editable: true, selected: true, checked: true,
    ancestor: true, descendant: true, rect: true, rectangle: true
  };
  function validatePredicates(value, path) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw failure('invalid_request', path + ' must be an object');
    Object.keys(value).forEach(function (key) {
      if (!predicateFields[key]) throw failure('invalid_request', 'unknown predicate field', { field: path + '.' + key });
      if (key === 'ancestor' || key === 'descendant') validatePredicates(value[key], path + '.' + key);
    });
  }

  function failure(code, message, details) { return ns.error(code, message, details); }
  function revision() { return core && Number.isInteger(core.revision) ? core.revision : 0; }
  function response(request, result, error) {
    var out = ns.response(request && request.action || 'unknown', revision(), result, error);
    out.document_id = core && core.documentId || null;
    out.frame_id = 0;
    return out;
  }
  function validate(request) {
    if (!request || typeof request !== 'object' || Array.isArray(request) || typeof request.action !== 'string') throw failure('invalid_request', 'action is required');
    if (ns.ACTIONS.indexOf(request.action) < 0) throw failure('invalid_request', 'unsupported content action');
    Object.keys(request).forEach(function (key) { if (!allowed[key]) throw failure('invalid_request', 'unknown request field', { field: key }); });
    if (request.action === 'find' && request.predicates !== undefined) validatePredicates(request.predicates, 'predicates');
    if (request.action === 'act' && (typeof request.ref !== 'string' || !request.ref || typeof request.operation !== 'string')) throw failure('invalid_request', 'act requires ref and operation');
    if ((request.action === 'inspect' || request.action === 'act') && typeof request.ref !== 'string') throw failure('invalid_request', request.action + ' requires ref');
    if (request.action === 'changes' && (!Number.isInteger(Number(request.since_revision)) || Number(request.since_revision) < 0)) throw failure('invalid_request', 'changes requires a non-negative since_revision');
    if (request.document_id != null && String(request.document_id) !== String(core.documentId)) throw failure('stale_document', 'request belongs to a previous document', { document_id: core.documentId });
  }
  async function handle(request) {
    try {
      validate(request);
      var result;
      if (request.action === 'outline') result = view.outline(Object.assign({}, request, { document: root.document }));
      else if (request.action === 'find') result = query.find(Object.assign({}, request, { document: root.document }), { core: core, view: view, document: root.document });
      else if (request.action === 'inspect') result = view.inspect(Object.assign({}, request, { document: root.document }));
      else if (request.action === 'act') result = await actions.act(request, { document: root.document, document_id: core.documentId, frame_id: 0 });
      else if (request.action === 'changes') {
        result = core.changesSince(request.since_revision, { max_nodes: request.max_nodes, max_text: request.max_text });
        if (result.expired) throw failure('revision_expired', 'mutation revision is no longer available; request a fresh outline', { revision: revision() });
      } else throw failure('unsupported_operation', 'action is handled by the background coordinator');
      if (result && result.error && result.error.code) throw result.error;
      return response(request, result);
    } catch (error) {
      var failureValue = error && error.code ? error : failure('invalid_request', error && error.message || String(error));
      return response(request || {}, null, failureValue);
    }
  }
  var api = { handle: handle, core: core };
  ns.register('main', api);
  if (root.browser && root.browser.runtime && root.browser.runtime.onMessage) root.browser.runtime.onMessage.addListener(handle);
  else if (root.chrome && root.chrome.runtime && root.chrome.runtime.onMessage) root.chrome.runtime.onMessage.addListener(handle);
})(typeof globalThis !== 'undefined' ? globalThis : this);
