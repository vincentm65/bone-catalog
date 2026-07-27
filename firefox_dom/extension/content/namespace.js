/* Wave 0 contract: the only shared global used by content modules. */
(function installFirefoxDOMNamespace(root) {
  'use strict';

  if (root.FirefoxDOM) return;

  var BUDGETS = Object.freeze({
    outlineNodes: 150,
    maxNodes: 500,
    maxDepth: 30,
    directText: 300,
    totalText: 30000,
    outlineText: 10000,
    inspectText: 12000,
    changesText: 6000,
    maxAttributes: 40,
    maxAttributeValue: 500,
    maxOptions: 200,
    maxMatches: 100,
    maxMessageBytes: 4 * 1024 * 1024
  });
  var ERRORS = Object.freeze([
    'invalid_request', 'invalid_selector', 'no_match', 'ambiguous_match',
    'invalid_ref', 'detached_node', 'stale_document', 'inaccessible_frame',
    'not_visible', 'covered_node', 'unsupported_operation', 'mutation_in_progress',
    'revision_expired', 'navigation_timeout', 'response_limit'
  ]);
  var ACTIONS = Object.freeze([
    'tabs', 'outline', 'find', 'inspect', 'act', 'changes', 'navigate', 'select_tab'
  ]);
  var OPERATIONS = Object.freeze([
    'click', 'focus', 'type', 'set_value', 'select', 'press', 'scroll_into_view',
    'scroll', 'check', 'uncheck', 'submit'
  ]);
  var MODULES = Object.freeze(['core', 'query', 'view', 'actions', 'background', 'main']);
  /* Requests are JSON objects with one action discriminator; unknown fields are rejected.
     Responses always have {ok, action, revision}; ok adds result, false adds error. */
  var PROTOCOL = freeze({
    request: freeze(['action', 'tab_id', 'frame_id', 'document_id', 'scope', 'ref', 'within', 'css', 'predicates', 'visible', 'depth', 'include', 'max_nodes', 'max_text', 'limit', 'operation', 'value', 'label', 'index', 'key', 'code', 'x', 'y', 'width', 'height', 'block', 'inline', 'observe_changes', 'settle_ms', 'since_revision', 'url']),
    response: freeze(['ok', 'action', 'revision', 'result', 'error']),
    error: freeze(['code', 'message', 'details']),
    ref: '<tab>:<document>:<frame>:<local-node>; components are non-empty and contain no colons'
  });

  function freeze(value) { return Object.freeze(value); }
  function error(code, message, details) {
    if (ERRORS.indexOf(code) < 0) code = 'invalid_request';
    var result = { code: code, message: String(message || code) };
    if (details !== undefined) result.details = details;
    return result;
  }
  function response(action, revision, result, failure) {
    var out = { ok: !failure, action: action, revision: revision == null ? 0 : revision };
    if (failure) out.error = failure.code ? failure : error(failure);
    else out.result = result === undefined ? null : result;
    return out;
  }
  function parseRef(ref) {
    if (typeof ref !== 'string' || !/^[^:]+:[^:]+:[^:]+:[^:]+$/.test(ref)) return null;
    var p = ref.split(':');
    return { tab: p[0], document: p[1], frame: p[2], local: p[3], ref: ref };
  }
  function makeRef(tab, document, frame, local) {
    if ([tab, document, frame, local].some(function (v) { return v == null || String(v).indexOf(':') >= 0 || String(v) === ''; })) return null;
    return [tab, document, frame, local].map(String).join(':');
  }

  /* These method names are the Wave 1 boundaries; implementations register separately. */
  var CONTRACTS = freeze({
    core: freeze(['documentId', 'revision', 'refFor', 'nodeFor', 'isConnected', 'walk', 'directText', 'redact', 'changesSince']),
    query: freeze(['find']),
    view: freeze(['outline', 'inspect', 'describe']),
    actions: freeze(['act']),
    background: freeze(['dispatch', 'resolveTab']),
    main: freeze(['handle'])
  });
  var modules = Object.create(null);
  var api = {
    VERSION: '0',
    BUDGETS: BUDGETS,
    PROTOCOL: PROTOCOL,
    ACTIONS: ACTIONS,
    OPERATIONS: OPERATIONS,
    ERRORS: ERRORS,
    CONTRACTS: CONTRACTS,
    modules: modules,
    error: error,
    response: response,
    parseRef: parseRef,
    makeRef: makeRef,
    register: function (name, implementation) {
      if (MODULES.indexOf(name) < 0) throw new Error('unknown FirefoxDOM module: ' + name);
      if (!implementation || typeof implementation !== 'object') throw new TypeError('module must be an object');
      modules[name] = implementation;
      return implementation;
    }
  };
  root.FirefoxDOM = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
