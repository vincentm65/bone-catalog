/* Firefox DOM background coordinator. It is deliberately DOM-free: all DOM work stays in content scripts. */
(function (root) {
  'use strict';

  var MAX_MESSAGE_BYTES = 4 * 1024 * 1024;
  var DEFAULT_MAX_NODES = 150;
  var DEFAULT_MAX_TEXT = 12000;
  var NAVIGATION_TIMEOUT = 15000;
  var MAX_NAVIGATION_TIMEOUT = 30000;
  var HOST = 'dev.bone.firefox_dom';
  var browserApi = root.browser || root.chrome;
  var mutationTail = Promise.resolve();
  var nativePort = null;

  function failure(code, message, details) {
    var out = { code: code, message: message || code };
    if (details !== undefined) out.details = details;
    return out;
  }
  function response(action, revision, result, error) {
    var out = { ok: !error, action: action, revision: Number.isInteger(revision) ? revision : 0 };
    if (error) out.error = error;
    else out.result = result === undefined ? null : result;
    return out;
  }
  function parseRef(ref) {
    if (typeof ref !== 'string') return null;
    var p = ref.split(':');
    if (p.length !== 4 || p.some(function (v) { return !v; })) return null;
    return { tab: p[0], document: p[1], frame: p[2], local: p[3], ref: ref };
  }
  function makeRef(tab, document, frame, local) {
    var values = [tab, document, frame, local].map(String);
    return values.some(function (v) { return !v || v.indexOf(':') >= 0; }) ? null : values.join(':');
  }
  function bytes(value) { return new TextEncoder().encode(JSON.stringify(value)).byteLength; }
  function bounded(value, action) {
    if (bytes(value) <= MAX_MESSAGE_BYTES) return value;
    return response(action, value.revision, null, failure('response_limit', 'response exceeds 4 MiB', { max_bytes: MAX_MESSAGE_BYTES }));
  }
  function refFor(tab, frame, local) {
    var documentId = frame.document_id || frame.document || frame.documentId;
    return documentId == null ? null : makeRef(tab.id, documentId, frame.frame_id == null ? frame.frameId : frame.frame_id, local);
  }
  function rewrite(value, tab, frame) {
    if (!value || typeof value !== 'object') return value;
    if (Array.isArray(value)) return value.map(function (v) { return rewrite(v, tab, frame); });
    var out = {};
    var refKeys = { ref: true, parent: true, shadow_host: true, hit: true, covered_by: true, active_descendant: true, covering_ref: true };
    var relationKeys = { labelled_by: true, described_by: true, controls: true, owns: true, active_descendant: true, label: true };
    function rewriteRef(value) {
      if (typeof value !== 'string') return rewrite(value, tab, frame);
      var parsed = parseRef(value);
      if (!parsed) return refFor(tab, frame, value) || value;
      /* Content cores emit document-local full refs (0:<document>:0:<local>).
         Qualify those too; leaving them parseable used to leak the local identity. */
      if (parsed.tab === '0' && parsed.frame === '0') return refFor(tab, frame, parsed.local) || value;
      return value;
    }
    Object.keys(value).forEach(function (key) {
      var v = value[key];
      if (refKeys[key] && (typeof v === 'string' || Array.isArray(v))) v = Array.isArray(v) ? v.map(rewriteRef) : rewriteRef(v);
      else if ((key === 'children' || key === 'assigned_nodes' || relationKeys[key]) && Array.isArray(v)) v = v.map(rewriteRef);
      else if (key === 'relations' && v && typeof v === 'object') {
        v = Object.keys(v).reduce(function (relations, relation) {
          relations[relation] = relationKeys[relation] && Array.isArray(v[relation]) ? v[relation].map(rewriteRef) : relationKeys[relation] ? rewriteRef(v[relation]) : rewrite(v[relation], tab, frame);
          return relations;
        }, {});
      } else v = rewrite(v, tab, frame);
      out[key] = v;
    });
    return out;
  }
  function native() {
    if (!browserApi || !browserApi.runtime || !browserApi.runtime.connectNative) throw new Error('browser native messaging unavailable');
    if (!nativePort) nativePort = browserApi.runtime.connectNative(HOST);
    return nativePort;
  }
  function frameList(tabId) {
    return Promise.resolve().then(function () {
      if (browserApi.webNavigation && browserApi.webNavigation.getAllFrames) return browserApi.webNavigation.getAllFrames({ tabId: tabId });
      return [{ frameId: 0 }];
    }).then(function (frames) { return frames && frames.length ? frames : [{ frameId: 0 }]; });
  }
  async function sendFrame(tab, frame, request) {
    try {
      var result = await browserApi.tabs.sendMessage(tab.id, request, { frameId: frame.frameId });
      if (!result || typeof result !== 'object') return response(request.action, 0, null, failure('invalid_request', 'content script returned no response'));
      frame = Object.assign({}, frame, { document_id: result.document_id || result.document || (result.result && result.result.document_id) || frame.document_id });
      return { frame: frame, response: bounded(rewrite(result, tab, frame), request.action) };
    } catch (e) {
      return { frame: frame, response: response(request.action, 0, null, failure('inaccessible_frame', 'frame is not accessible', { frame_id: frame.frameId })) };
    }
  }
  async function resolveTab(request) {
    if (request.tab_id != null) {
      try { return (await browserApi.tabs.get(request.tab_id)); } catch (_) { return null; }
    }
    var tabs = await browserApi.tabs.query({ active: true, currentWindow: true });
    return tabs && tabs[0] || null;
  }
  function budgetNumber(value, fallback) {
    value = Number(value);
    return Number.isFinite(value) && value >= 0 ? Math.floor(value) : fallback;
  }
  function navigationTimeout(value) {
    value = Number(value);
    if (!Number.isFinite(value)) value = NAVIGATION_TIMEOUT;
    return Math.max(1000, Math.min(MAX_NAVIGATION_TIMEOUT, Math.floor(value)));
  }
  function budgetResult(action, frames, request) {
    var maxNodes = budgetNumber(request.max_nodes, DEFAULT_MAX_NODES);
    var maxText = budgetNumber(request.max_text, DEFAULT_MAX_TEXT);
    var usedNodes = 0, usedText = 0;
    var omittedNodes = frames.reduce(function (total, frame) {
      var result = frame.result || {};
      return total + (Number(result.omitted_nodes) || Number(result.omitted) || 0);
    }, 0);
    var omittedText = frames.reduce(function (total, frame) {
      return total + (Number(frame.result && frame.result.omitted_text) || 0);
    }, 0);
    function keepRecord(record) {
      if (usedNodes >= maxNodes) {
        omittedNodes += 1;
        omittedText += typeof record.direct_text === 'string' ? record.direct_text.length : 0;
        return null;
      }
      var out = Object.assign({}, record);
      usedNodes += 1;
      if (typeof out.direct_text === 'string') {
        var remaining = Math.max(0, maxText - usedText);
        if (out.direct_text.length > remaining) {
          omittedText += out.direct_text.length - remaining;
          out.direct_text = out.direct_text.slice(0, remaining);
          out.truncated = true;
        }
        usedText += out.direct_text.length;
      }
      return out;
    }
    function trimResult(result) {
      if (!result || typeof result !== 'object') return result;
      var out = Object.assign({}, result);
      var key = action === 'find' ? 'matches' : action === 'changes' ? 'changes' : action === 'outline' ? 'nodes' : null;
      if (key && Array.isArray(result[key])) {
        out[key] = result[key].map(keepRecord).filter(Boolean);
        var localOmitted = result[key].length - out[key].length;
        out.omitted_nodes = (Number(result.omitted_nodes) || 0) + localOmitted;
        out.truncated = !!out.truncated || localOmitted > 0;
      } else if (action === 'inspect') {
        ['node', 'ancestors', 'siblings', 'descendants', 'options'].forEach(function (key) {
          if (Array.isArray(result[key])) out[key] = result[key].map(keepRecord).filter(Boolean);
          else if (result[key] && typeof result[key] === 'object' && key === 'node') out[key] = keepRecord(result[key]);
        });
      }
      return out;
    }
    var outputFrames = frames.map(function (frame) { return Object.assign({}, frame, { result: trimResult(frame.result) }); });
    return { frames: outputFrames, omitted_nodes: omittedNodes, omitted_text: omittedText, truncated: omittedNodes > 0 || omittedText > 0,
      continuation_hint: omittedNodes > 0 || omittedText > 0 ? 'Narrow the scope, selector, include set, or frame; continue from a returned ref.' : undefined };
  }
  function aggregate(request, tab, results) {
    var accessible = results.filter(function (x) { return x.response.ok; });
    var failures = results.filter(function (x) { return !x.response.ok; });
    var inaccessible = failures.filter(function (x) { return x.response.error.code === 'inaccessible_frame'; });
    var otherFailures = failures.filter(function (x) { return x.response.error.code !== 'inaccessible_frame'; });
    if (!accessible.length) {
      if (otherFailures.length) return otherFailures[0].response;
      return response(request.action, 0, null, failure('inaccessible_frame', 'no accessible frames', { frames: inaccessible.map(function (x) { return x.frame.frameId; }) }));
    }
    var revision = accessible.reduce(function (n, x) { return Math.max(n, x.response.revision || 0); }, 0);
    var frames = accessible.map(function (x) { return { frame_id: x.frame.frameId, revision: x.response.revision || 0, result: x.response.result }; });
    var result = budgetResult(request.action, frames, request);
    result.tab_id = tab.id;
    result.inaccessible_frames = inaccessible.map(function (x) { return { frame_id: x.frame.frameId, error: x.response.error }; });
    result.errors = otherFailures.map(function (x) { return { frame_id: x.frame.frameId, error: x.response.error }; });
    result.omitted_frames = inaccessible.length;
    result.truncated = result.truncated || inaccessible.length > 0 || otherFailures.length > 0;
    return bounded(response(request.action, revision, result), request.action);
  }
  async function dispatch(request) {
    if (!request || typeof request !== 'object' || typeof request.action !== 'string') return response('unknown', 0, null, failure('invalid_request', 'action is required'));
    var action = request.action;
    if (action === 'tabs') return bounded(response(action, 0, await browserApi.tabs.query({ currentWindow: true })), action);
    if (action === 'select_tab') {
      if (request.tab_id == null) return response(action, 0, null, failure('invalid_request', 'tab_id is required'));
      try { await browserApi.tabs.update(request.tab_id, { active: true }); return response(action, 0, { tab_id: request.tab_id }); }
      catch (_) { return response(action, 0, null, failure('invalid_request', 'tab does not exist')); }
    }
    var tab = await resolveTab(request);
    if (!tab) return response(action, 0, null, failure('invalid_request', 'tab does not exist'));
    if (action === 'navigate') {
      if (typeof request.url !== 'string' || !request.url) return response(action, 0, null, failure('invalid_request', 'url is required'));
      var timeoutMs = navigationTimeout(request.timeout_ms);
      var finishNavigation = null;
      var completed = new Promise(function (resolve) {
        var settled = false, timer = null;
        var finish = function (value) {
          if (settled) return;
          settled = true;
          if (browserApi.tabs.onUpdated && browserApi.tabs.onUpdated.removeListener) browserApi.tabs.onUpdated.removeListener(listener);
          if (timer !== null) clearTimeout(timer);
          resolve(value);
        };
        finishNavigation = finish;
        /* tabs.onUpdated supplies (tabId, changeInfo, tab), not a webNavigation
           details object. It only reports top-level tab navigation here. */
        var listener = function (tabId, changeInfo) {
          if (tabId === tab.id && changeInfo && changeInfo.status === 'complete') finish(true);
        };
        if (browserApi.tabs.onUpdated && browserApi.tabs.onUpdated.addListener) browserApi.tabs.onUpdated.addListener(listener);
        timer = setTimeout(function () { finish(false); }, timeoutMs);
      });
      try { await browserApi.tabs.update(tab.id, { url: request.url }); }
      catch (_) {
        finishNavigation(false);
        return response(action, 0, null, failure('invalid_request', 'navigation failed'));
      }
      if (!(await completed)) return response(action, 0, null, failure('navigation_timeout', 'navigation did not complete', { timeout_ms: timeoutMs }));
      return response(action, 0, { tab_id: tab.id, url: request.url });
    }
    function parseInbound(name) {
      if (request[name] == null) return null;
      var value = request[name];
      var parsedValue = parseRef(value);
      if (!parsedValue || String(tab.id) !== parsedValue.tab) return { error: failure('invalid_ref', name + ' does not belong to the selected tab') };
      return parsedValue;
    }
    var parsed = parseInbound('ref');
    var within = parseInbound('within');
    if (parsed && parsed.error) return response(action, 0, null, parsed.error);
    if (within && within.error) return response(action, 0, null, within.error);
    if (parsed && within && (parsed.document !== within.document || parsed.frame !== within.frame)) {
      return response(action, 0, null, failure('invalid_ref', 'ref and within identify different documents or frames'));
    }
    if (parsed && action === 'changes') return response(action, 0, null, failure('invalid_request', 'changes does not accept ref'));
    var identity = parsed || within;
    if (request.frame_id != null && !Number.isInteger(Number(request.frame_id))) return response(action, 0, null, failure('invalid_request', 'frame_id must be an integer'));
    if (identity && request.frame_id != null && String(request.frame_id) !== identity.frame) {
      return response(action, 0, null, failure('invalid_ref', 'ref or within conflicts with frame_id', { frame_id: Number(request.frame_id) }));
    }
    var frames = await frameList(tab.id);
    if (request.frame_id != null) frames = frames.filter(function (f) { return String(f.frameId) === String(request.frame_id); });
    if (identity) frames = frames.filter(function (f) { return String(f.frameId) === identity.frame; });
    if (!frames.length) {
      if (request.frame_id != null && !identity) return response(action, 0, null, failure('inaccessible_frame', 'requested frame is not accessible', { frame_id: Number(request.frame_id) }));
      return response(action, 0, null, failure('invalid_ref', 'frame is not available', { frame_id: Number(identity.frame) }));
    }
    if (identity) {
      var frameDocument = frames[0].document_id || frames[0].documentId || frames[0].document;
      if (frameDocument != null && String(frameDocument) !== identity.document) return response(action, 0, null, failure('invalid_ref', 'ref belongs to a previous document', { document_id: frameDocument }));
    }
    if (action === 'changes' && request.frame_id == null) {
      frames = frames.filter(function (f) { return String(f.frameId) === '0'; });
      if (!frames.length) return response(action, 0, null, failure('inaccessible_frame', 'main frame is not accessible', { frame_id: 0 }));
    }
    var routed = Object.assign({}, request);
    if (parsed) {
      /* Content cores resolve document-local refs only. Route by the external
         identity first, then send the normalized local full ref inward. */
      routed.ref = makeRef('0', parsed.document, '0', parsed.local);
      routed.document_id = parsed.document;
    }
    if (within) {
      routed.within = makeRef('0', within.document, '0', within.local);
      routed.document_id = within.document;
    }
    var results = await Promise.all(frames.map(function (frame) { return sendFrame(tab, frame, routed); }));
    if (parsed) { var one = results[0]; return bounded(one.response, action); }
    return aggregate(request, tab, results);
  }
  function dispatchSerialized(request) {
    var mutating = request && (request.action === 'act' || request.action === 'navigate' || request.action === 'select_tab');
    var run = function () { return dispatch(request); };
    if (!mutating) return run();
    var next = mutationTail.then(run, run);
    mutationTail = next.then(function () {}, function () {});
    return next;
  }
  function install() {
    if (!browserApi || !browserApi.runtime) return;
    if (browserApi.runtime.onMessage) browserApi.runtime.onMessage.addListener(function (request) { return dispatchSerialized(request); });
    // Native messages are requests from the Lua/tool side. Keep the host identity
    // dedicated and return the coordinator's structured response unchanged.
    if (browserApi.runtime.connectNative) {
      try {
        var port = native();
        if (port && port.onMessage) port.onMessage.addListener(function (request) {
          dispatchSerialized(request).then(function (result) {
            try { port.postMessage(bounded(result, request && request.action)); } catch (_) {}
          });
        });
      } catch (_) {}
    }
    if (browserApi.runtime.onConnect) browserApi.runtime.onConnect.addListener(function (port) {
      if (port.name !== HOST) return;
      port.onMessage.addListener(function (request) { dispatchSerialized(request).then(function (result) { port.postMessage(bounded(result, request && request.action)); }); });
    });
  }
  var api = { dispatch: dispatchSerialized, parseRef: parseRef, makeRef: makeRef, install: install, constants: { HOST: HOST, MAX_MESSAGE_BYTES: MAX_MESSAGE_BYTES, NAVIGATION_TIMEOUT: NAVIGATION_TIMEOUT, MAX_NAVIGATION_TIMEOUT: MAX_NAVIGATION_TIMEOUT } };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.FirefoxDOMBackground = api;
  install();
})(typeof globalThis !== 'undefined' ? globalThis : this);
