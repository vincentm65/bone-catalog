/* Wave 1A: document-local identity, composed traversal, and bounded primitives. */
(function installFirefoxDOMCore(root) {
  'use strict';

  var dom = root.FirefoxDOM;
  if (!dom) throw new Error('FirefoxDOM namespace must load before dom-core.js');

  function makeCore(options) {
    options = options || {};
    var doc = options.document || root.document;
    if (!doc) throw new Error('document is required');
    var budgets = dom.BUDGETS;
    var documentId = String(options.documentId || newDocumentId());
    var revision = 0;
    var nextLocal = 1;
    var byNode = new WeakMap();
    var byLocal = new Map();
    var registryOrder = [];
    /* Connected refs remain addressable; only detached lifetimes are tombstones. */
    var registryLimit = Math.max(1, Number(options.registryLimit || options.tombstoneLimit || 1024));
    var history = [];
    var historyLimit = Math.max(1, Number(options.mutationHistory || 64));
    var mutationBatchLimit = Math.max(1, Number(options.mutationBatchLimit || budgets.maxNodes));
    var observer = null;

    function newDocumentId() {
      return 'd' + Math.random().toString(36).slice(2, 10);
    }
    function element(node) { return !!node && node.nodeType === 1; }
    function connected(node) {
      if (!element(node) || node.ownerDocument !== doc) return false;
      if (typeof node.isConnected === 'boolean' && node.isConnected) return true;
      var n = node;
      while (n) {
        if (n === doc.documentElement) return true;
        if (n.host) { n = n.host; continue; }
        n = n.parentNode;
      }
      var info = byNode.get(node);
      if (info) info.connected = false;
      return false;
    }
    function pruneTombstones() {
      var detached = [];
      for (var i = 0; i < registryOrder.length; i++) {
        var local = registryOrder[i], node = byLocal.get(local), info = node && byNode.get(node);
        if (info && !info.connected) detached.push(i);
      }
      while (detached.length > registryLimit) {
        var index = detached.shift(), oldLocal = registryOrder[index];
        registryOrder.splice(index, 1);
        byLocal.delete(oldLocal);
        detached = detached.map(function (value) { return value > index ? value - 1 : value; });
      }
    }
    function registerLocal(local, node) {
      byLocal.set(local, node);
      registryOrder.push(local);
      pruneTombstones();
    }
    function localFor(node) {
      if (!element(node) || node.ownerDocument !== doc || !connected(node)) return null;
      var old = byNode.get(node);
      if (old && old.connected && connected(node)) return old.local;
      if (old) old.connected = false;
      var local = 'n' + nextLocal++;
      byNode.set(node, { local: local, connected: true, lifetime: nextLocal });
      registerLocal(local, node);
      return local;
    }
    function refFor(node) {
      var local = localFor(node);
      return local == null ? null : dom.makeRef(options.tabId == null ? '0' : options.tabId, documentId, options.frameId == null ? '0' : options.frameId, local);
    }
    function knownRef(node) {
      var info = byNode.get(node);
      return info ? dom.makeRef(options.tabId == null ? '0' : options.tabId, documentId, options.frameId == null ? '0' : options.frameId, info.local) : null;
    }
    function nodeFor(ref) {
      var parsed = dom.parseRef(ref);
      if (parsed) {
        if (parsed.document !== documentId || parsed.frame !== String(options.frameId == null ? '0' : options.frameId)) return null;
        return byLocal.get(parsed.local) || null;
      }
      /* The background coordinator strips the external prefix before routing. */
      if (typeof ref === 'string' && /^[^:]+$/.test(ref)) return byLocal.get(ref) || null;
      return null;
    }
    function markDisconnected(node) {
      if (!node) return;
      if (element(node)) {
        var info = byNode.get(node);
        if (info) info.connected = false;
      }
      for (var child of Array.from(node.childNodes || [])) markDisconnected(child);
      if (node.shadowRoot) markDisconnected(node.shadowRoot);
      pruneTombstones();
    }
    function ownerElement(node) {
      if (!node) return null;
      if (element(node)) return node;
      var parent = node.parentElement || node.parentNode;
      while (parent && !element(parent)) parent = parent.host || parent.parentNode;
      return parent || null;
    }
    function childrenOf(node) {
      if (!node) return [];
      var list = node.children;
      if (list) return Array.prototype.slice.call(list);
      return Array.prototype.slice.call(node.childNodes || []).filter(element);
    }
    function assigned(slot) {
      if (!slot || typeof slot.assignedNodes !== 'function') return [];
      var result;
      try { result = slot.assignedNodes({ flatten: true }); } catch (_) { result = slot.assignedNodes(); }
      return Array.prototype.slice.call(result || []).filter(element);
    }
    function walk(start, walkOptions) {
      walkOptions = walkOptions || {};
      var out = [], seen = new Set();
      function visit(node) {
        if (!node || seen.has(node)) return;
        if (element(node)) { seen.add(node); out.push(node); }
        if (node.localName === 'slot') {
          var assignedNodes = assigned(node);
          if (assignedNodes.length) { for (var a of assignedNodes) visit(a); }
          else for (var fallback of childrenOf(node)) visit(fallback);
          return;
        }
        var shadow = node.shadowRoot;
        if (shadow && shadow.mode !== 'closed') {
          for (var s of childrenOf(shadow)) visit(s);
          return;
        }
        for (var child of childrenOf(node)) visit(child);
      }
      if (start && start.nodeType === 9) visit(start.documentElement);
      else if (start && start.nodeType === 11) for (var rootChild of childrenOf(start)) visit(rootChild);
      else visit(start || doc.documentElement);
      return out;
    }
    function directText(node, max) {
      max = Math.min(Number(max) || budgets.directText, budgets.directText);
      if (!element(node) || node.localName === 'script' || node.localName === 'style') return '';
      var nodes = Array.prototype.slice.call(node.childNodes || []);
      var textNodes = nodes.filter(function (n) { return n.nodeType === 3; });
      var text = textNodes.map(function (n) { return n.textContent || ''; }).join('');
      /* Test doubles may expose textContent without materialized text nodes. */
      if (!textNodes.length && !nodes.some(function (n) { return n.nodeType === 1; })) text = node.textContent || '';
      text = text.replace(/\s+/g, ' ').trim();
      return text.slice(0, max);
    }
    function normalized(value) { return String(value == null ? '' : value).toLowerCase().replace(/[^a-z0-9]/g, ''); }
    function sensitiveName(value) {
      var name = normalized(value);
      return /^(hidden|password|passwd)$/.test(name) || /(?:token|csrf|secret|session|auth|authorization|credential|password|passwd|apikey)/.test(name) || /key$/.test(name);
    }
    function sensitive(name, node) {
      var markers = [name];
      if (node) {
        markers.push(node.type, node.name, node.id);
        if (node.attributes) for (var i = 0; i < node.attributes.length; i++) markers.push(node.attributes[i].name);
        if (node.getAttribute) markers.push(node.getAttribute('type'), node.getAttribute('name'), node.getAttribute('id'));
      }
      return markers.some(sensitiveName);
    }
    function redactUrl(value) {
      var text = String(value);
      /* Strip user-info without changing ordinary URL paths, hosts, or fragments. */
      text = text.replace(/^([a-z][a-z0-9+.-]*:\/\/)([^\/?#@]*)(@)/i, '$1[REDACTED]$3');
      var hash = text.indexOf('#'), fragment = hash < 0 ? '' : text.slice(hash), beforeHash = hash < 0 ? text : text.slice(0, hash);
      var question = beforeHash.indexOf('?');
      if (question < 0) return text;
      var base = beforeHash.slice(0, question), query = beforeHash.slice(question + 1);
      query = query.split('&').map(function (part) {
        var equals = part.indexOf('='), key = equals < 0 ? part : part.slice(0, equals);
        return sensitiveName(key) ? key + (equals < 0 ? '=[REDACTED]' : '=[REDACTED]') : part;
      }).join('&');
      return base + '?' + query + fragment;
    }
    function redact(value, context, field) {
      var node = null, name = context;
      if (value && typeof value === 'object' && value.nodeType === 1) { node = value; value = context; name = field; }
      else if (context && context.node) { node = context.node; name = field || context.field || ''; }
      if (sensitive(name, node)) return '[REDACTED]';
      if (value == null) return value;
      var output = String(value);
      if (/^(href|src|action|formaction)$/i.test(String(name || ''))) output = redactUrl(output);
      return output.slice(0, budgets.maxAttributeValue);
    }
    function bounded(value, limit) {
      var text = String(value == null ? '' : value);
      limit = Math.max(0, Math.min(Number(limit) || budgets.maxAttributeValue, budgets.maxAttributeValue));
      return { value: text.slice(0, limit), truncated: text.length > limit, omitted: Math.max(0, text.length - limit) };
    }
    function recordMutations(records) {
      var input = Array.prototype.slice.call(records || []), overflow = input.length > mutationBatchLimit;
      records = input.slice(0, mutationBatchLimit);
      if (!records.length) return revision;
      revision += 1;
      var changes = new Map();
      function add(node, kind) {
        if (node && node.nodeType === 3) node = ownerElement(node);
        if (!element(node)) return;
        var old = changes.get(node);
        if (!old) { old = { node: node, kinds: new Set() }; changes.set(node, old); }
        old.kinds.add(kind);
      }
      for (var record of records) {
        if (record.type === 'attributes') add(record.target, 'updated');
        else { add(record.target, 'updated'); for (var a of Array.from(record.addedNodes || [])) add(a, 'added'); for (var r of Array.from(record.removedNodes || [])) { markDisconnected(r); add(r, 'removed'); } }
      }
      if (changes.size > mutationBatchLimit) overflow = true;
      history.push({ revision: revision, changes: Array.from(changes.values()).slice(0, mutationBatchLimit), overflow: overflow });
      while (history.length > historyLimit) history.shift();
      return revision;
    }
    function changesSince(since, limits) {
      since = Number(since);
      limits = limits || {};
      var max = Math.min(Number(limits.max_nodes) || budgets.maxNodes, budgets.maxNodes);
      if (!Number.isInteger(since) || since < 0) return { revision: revision, changes: [], expired: true };
      if (since === revision) return { revision: revision, changes: [], expired: false, truncated: false };
      if (history.length && since < history[0].revision - 1) return { revision: revision, changes: [], expired: true, since_revision: since };
      var flat = [], overflow = false;
      for (var batch of history) if (batch.revision > since) {
        overflow = overflow || !!batch.overflow;
        for (var item of batch.changes) {
          var ref = refFor(item.node) || knownRef(item.node);
          var existing = flat.find(function (x) { return x.ref === ref; });
          if (existing) existing.kinds = Array.from(new Set(existing.kinds.concat(Array.from(item.kinds))));
          else flat.push({ ref: ref, kinds: Array.from(item.kinds) });
        }
      }
      var truncated = flat.length > max;
      return { revision: revision, changes: flat.slice(0, max), truncated: truncated, omitted: Math.max(0, flat.length - max), overflow: overflow, fresh_outline: overflow || truncated, expired: false };
    }
    if (typeof root.MutationObserver === 'function' && options.observe !== false) {
      observer = new root.MutationObserver(recordMutations);
      observer.observe(doc, { subtree: true, childList: true, attributes: true, characterData: true });
    }
    var api = {
      get documentId() { return documentId; },
      get revision() { return revision; },
      refFor: refFor, nodeFor: nodeFor,
      isConnected: connected,
      walk: walk, directText: directText, redact: redact, bounded: bounded,
      budgets: budgets, recordMutations: recordMutations, changesSince: changesSince,
      destroy: function () { if (observer) observer.disconnect(); observer = null; }
    };
    return api;
  }

  var core = root.document ? makeCore({ document: root.document }) : null;
  dom.createCore = makeCore;
  if (core) dom.register('core', core);
})(typeof globalThis !== 'undefined' ? globalThis : this);
