# Firefox DOM Tool Plan

## Goal

Build a new `firefox_dom` tool that lets an LLM discover, inspect, and act on ordinary DOM elements in the user's normal Firefox session without sending full-page HTML to model context.

The complete live DOM index stays inside the WebExtension. The tool returns bounded outlines, search results, node details, and mutation summaries. Accessibility metadata is included as useful context but does not decide which elements are discoverable.

This is a greenfield tool. It does not extend or preserve the current `firefox` tool's protocol, refs, observation model, extension, native host, setup command, or package. The current tool remains untouched while `firefox_dom` is developed and evaluated.

## Success criteria

The agent can:

- Find any ordinary element in extension-accessible DOM, including unlabeled custom elements and structural nodes.
- Understand ancestry, children, nearby text, geometry, frame, and open shadow-root context.
- Search the complete local DOM index without putting the complete index into context.
- Expand a selected subtree on demand.
- Click, focus, type into, scroll to, check, and select supported controls by stable node ID.
- Open a custom dropdown, receive a bounded mutation summary, and select a newly exposed option.
- Select a native `<select>` option by label or value.
- Detect focus and relevant DOM changes after an action.
- Operate large pages under fixed node, depth, attribute, and text budgets.
- Redact passwords and sensitive hidden values.

A typical viewport outline should remain below 150 nodes and 10,000 text characters. Every truncated response must say what was omitted and how to narrow or continue it.

## Non-goals

- Returning raw full-page HTML.
- Arbitrary JavaScript evaluation.
- Reading cookies, storage, browser history, network traffic, or browser credentials.
- Inspecting Firefox-privileged pages.
- Piercing closed shadow roots.
- Understanding pixels inside canvas, video, or images as DOM.
- Guaranteeing trusted physical input from a WebExtension. Synthetic events remain untrusted.
- Silently adding OS-level input injection, WebDriver, Marionette, or remote-debugging control.
- Sharing mutable runtime state or protocol compatibility with the existing `firefox` tool.

## Product boundary

Use a separate catalog item and runtime identity:

- Tool: `firefox_dom`
- Command: `/firefox_dom setup|doctor|remove`
- Native host: `dev.bone.firefox_dom`
- Socket: `bone-firefox-dom.sock`
- Extension ID: `firefox-dom@bone.local`
- Package: `bone-firefox-dom-0.1.0.zip`

The implementation may copy proven transport and setup patterns from the existing bridge, but it owns separate source, state, manifests, process identity, and tests.

## Architecture

### 1. WebExtension background coordinator

Responsibilities:

- Connect to the dedicated native host.
- Resolve active or explicit tabs.
- Discover extension-accessible frames.
- Route requests to one frame or aggregate across frames.
- Prefix local node IDs with tab, document, and frame identity.
- Serialize mutations so actions cannot race.
- Preserve structured errors and enforce response limits.

It does not inspect DOM itself.

### 2. Per-frame DOM agent

Each content-script instance owns:

- A document ID that changes on navigation.
- `WeakMap<Element, localNodeId>` and reverse lookup for connected nodes.
- Composed-tree traversal across ordinary children, slots, and open shadow roots.
- Live search over the current DOM.
- Outline pruning and subtree inspection.
- Mutation revision tracking through `MutationObserver`.
- Node actions and before/after state capture.
- Redaction and hard response budgets.

The DOM should be queried live rather than copied into a permanent serialized mirror. “DOM index” means a browser-side identity/query layer over the live document, not a second full DOM implementation.

### 3. Native host

Responsibilities only:

- Firefox native-messaging framing.
- Owner-only local Unix socket.
- Request/response correlation.
- Message-size limits and timeouts.
- Per-request client connection handling.

It does not understand DOM requests or mutate payloads.

### 4. Lua tool adapter

Responsibilities:

- Publish the tool schema.
- Invoke the native host.
- Set conservative timeouts.
- Return structured JSON unchanged.
- Tell the model to inspect narrowly, act sequentially, and avoid guessing ambiguous nodes.

## Source layout

Keep parallel work isolated by module ownership:

```text
firefox_dom/
  README.md
  setup.sh
  bridge/
    Cargo.toml
    Cargo.lock
    src/main.rs
  extension/
    manifest.json
    background.js
    content/
      namespace.js
      dom-core.js
      dom-query.js
      dom-view.js
      dom-actions.js
      content-main.js
commands/firefox_dom.lua
tools/firefox_dom.lua
tests/
  firefox_dom_harness.mjs
  firefox_dom_core_test.mjs
  firefox_dom_query_test.mjs
  firefox_dom_view_test.mjs
  firefox_dom_actions_test.mjs
  firefox_dom_background_test.mjs
  firefox_dom_tool_test.lua
```

Manifest V2 content scripts load the content modules in the listed order. Each module attaches only its documented API to one namespace such as `globalThis.FirefoxDOM`; no build step is required.

## Node identity and lifetime

External node refs use:

```text
<tab>:<document>:<frame>:<local-node>
```

Rules:

- A local ID is stable for one element's connected lifetime.
- A new document receives a new document ID.
- Re-observation does not invalidate connected node refs.
- A disconnected or replaced node returns `detached_node`.
- A navigation returns `stale_document` for old refs.
- Every response includes the current document revision.
- Actions validate tab, document, frame, node connection, visibility requirements, and ambiguity before mutation.

## Composed-tree model

Traversal includes:

- Element children in source order.
- Open shadow roots, with an explicit shadow-boundary marker.
- Slot assigned elements using flattened assignment order.
- HTML and SVG elements.
- Separate frame roots coordinated by the background script.

Traversal must avoid duplicate slotted nodes and cycles. Closed shadow hosts are represented as hosts with `closed_shadow_root: true` when detectable; their internals remain inaccessible.

Text nodes are folded into their owning element as bounded `direct_text`. They do not receive actionable refs.

## Node data model

The browser can derive all fields, but responses include only fields appropriate to the requested detail level.

### Identity and structure

- `ref`
- `tag`
- `namespace` when non-HTML
- `parent`
- `children` or child count
- `frame_id`
- `shadow_host`
- `slot`
- Source order

### Text and semantics

- Bounded direct text
- Bounded descendant text only on explicit inspection
- Accessible name
- Associated label text
- Nearby sibling text
- Role
- Placeholder and title

### Attributes and properties

Outline mode uses a strict allowlist. Inspection may return bounded additional attributes.

Important fields include:

- `id`, bounded classes, `name`, `type`, `href`, `for`, `tabindex`
- `contenteditable`, `disabled`, `readonly`, `required`
- All bounded `aria-*` attributes
- Current `value`, `checked`, `selected`, `indeterminate`, and `open` properties
- Native select options on explicit inspection, with a separate option limit

Never return password values, hidden input values, script contents, style contents, or URL credentials. Treat likely token/secret fields conservatively by name and type.

### Rendered and interaction state

- Bounding rectangle
- Viewport intersection
- `display`, `visibility`, `opacity`, and `pointer-events` only as normalized state
- Visible, focusable, focused, editable, disabled, checked, selected
- Scrollability
- Fixed/sticky status when relevant
- Center-point hit-test result and covering node when available
- Interaction hints such as native control, link, inline click handler, non-default `onclick` property, or pointer cursor

Interaction hints are advisory. The tool must not claim it can enumerate every JavaScript event listener.

## Tool protocol

Use one tool with a required `action` discriminator. Unknown fields are rejected.

### `tabs`

Returns bounded tab metadata for the current window.

```json
{ "action": "tabs" }
```

### `outline`

Returns a compact hierarchical projection.

```json
{
  "action": "outline",
  "tab_id": 7,
  "scope": "viewport",
  "max_nodes": 150,
  "max_text": 10000,
  "depth": 12
}
```

Scopes:

- `viewport` (default)
- `document`
- `focused`
- `region`, requiring `x`, `y`, `width`, and `height`
- `subtree`, requiring `ref`

The response contains frame roots and flat node records with `parent`/`children`, so JSON does not recursively duplicate data. It includes `truncated`, omitted counts, and a continuation or narrowing hint.

### `find`

Searches live DOM and returns compact matches plus enough ancestry to disambiguate them.

```json
{
  "action": "find",
  "css": "[aria-haspopup='listbox']",
  "within": "7:d3:0:n21",
  "visible": true,
  "limit": 20
}
```

Structured predicates may include:

- `tag`, `id`, `class`
- Attribute presence or exact value
- Direct or descendant text, exact or contains
- Accessible name and role
- Visible, focused, focusable, enabled, editable, selected, checked
- Rectangle intersection
- Ancestor/descendant scope

CSS is discovery-only, bounded, and caught on invalid syntax. Custom traversal applies the selector independently in each open tree root. Cross-frame aggregation occurs only when `frame_id` is omitted. Mutations never accept CSS directly; they require one returned node ref.

### `inspect`

Returns one node, bounded ancestors, relations, siblings, and descendants.

```json
{
  "action": "inspect",
  "ref": "7:d3:0:n32",
  "depth": 2,
  "include": ["ancestors", "children", "siblings", "relations", "options"],
  "max_nodes": 200,
  "max_text": 12000
}
```

Relations include label, labelled-by, described-by, controls, owns, active-descendant, and form ownership where resolvable in the applicable tree scope.

### `act`

Performs one explicit operation on one node ref.

```json
{
  "action": "act",
  "ref": "7:d3:0:n32",
  "operation": "click",
  "observe_changes": true,
  "settle_ms": 300
}
```

Initial operations:

- `click`
- `focus`
- `type`
- `set_value`
- `select`
- `press`
- `scroll_into_view`
- `scroll`
- `check`
- `uncheck`
- `submit`

Return target state and focus before/after. If requested, settle briefly and include a bounded mutation summary.

Native `select` accepts exactly one of `label`, `value`, or `index`, rejects ambiguous labels, applies the native property, and dispatches `input` and `change`.

Custom dropdowns use click → changes/outline → option ref → click. Do not manipulate undocumented component internals.

### `changes`

Returns bounded mutations since a known revision.

```json
{
  "action": "changes",
  "tab_id": 7,
  "frame_id": 0,
  "since_revision": 42,
  "max_nodes": 100,
  "max_text": 6000
}
```

Report added, removed, and materially updated nodes. Coalesce noisy mutations and indicate overflow. Mutation history is a small ring buffer; an old revision returns `revision_expired` and asks for a fresh outline.

### `navigate` and `select_tab`

These remain explicit top-level actions because they do not target DOM nodes. Navigation waits with a bounded timeout and returns a new document identity plus an optional outline.

## Outline pruning

The local index includes every ordinary element, but default outlines retain only nodes useful for understanding or interaction:

- Nodes with direct text
- Native controls and links
- Focusable or editable nodes
- Custom elements
- Nodes with relevant ARIA or interaction hints
- Forms, dialogs, tables, lists, menus, popups, major regions, and scroll containers
- Meaningful visual leaves
- Structural ancestors needed to connect retained descendants

Collapse chains of attribute-free, text-free wrappers. `find` must still locate collapsed elements, and `inspect` must reveal them when requested.

Do not repeat aggregated ancestor text. Prefer direct text and child structure.

## Budgets and redaction

Enforce limits in the content script even if the caller supplies larger values:

- Maximum 500 returned nodes per frame and request
- Default 150 outline nodes
- Maximum depth 30
- Maximum direct text 300 characters per node
- Maximum total text 30,000 characters per frame; lower defaults by action
- Maximum 40 attributes per inspected node
- Maximum attribute value 500 characters
- Maximum 200 native options
- Maximum 100 search matches
- Native message maximum 4 MiB

Return explicit truncation metadata. Never silently drop frames or overflow mutation history.

Redact:

- Password values
- Hidden input values
- Values whose field names strongly indicate token, secret, session, authorization, or credential data
- URL userinfo

Do not return script/style text or inline script bodies. Inline handler presence may be reported without handler source.

## Structured errors

At minimum:

- `invalid_request`
- `invalid_selector`
- `no_match`
- `ambiguous_match`
- `invalid_ref`
- `detached_node`
- `stale_document`
- `inaccessible_frame`
- `not_visible`
- `covered_node`
- `unsupported_operation`
- `mutation_in_progress`
- `revision_expired`
- `navigation_timeout`
- `response_limit`

Errors include a stable code, human-readable message, and only bounded diagnostic details.

## Parallel execution plan

### Coordination rules

- Run work in waves. Tasks in one wave may run in parallel; the next wave starts only after required contracts land.
- Give every Luna subagent the frozen protocol section and its exact file ownership.
- No two implementation agents edit the same file.
- Agents may add tests only in their assigned test file.
- Shared wiring files are owned by the integration agent in Wave 2.
- Each agent returns changed files, assumptions, unresolved issues, and validation commands.
- Do not let agents modify `catalog.json`, `gen-index.sh`, package ZIPs, or current Firefox tool files during Wave 1.

### Wave 0 — contract and skeleton (lead, serial)

Create directories, empty module namespaces, manifest load order, protocol fixtures, and shared test harness interfaces. Freeze:

- Namespace API between content modules
- Request and response shapes
- Node-ref format
- Error shape
- Budget defaults and hard limits
- Test fake-DOM contracts

Files owned by lead:

- `firefox_dom/extension/content/namespace.js`
- `firefox_dom/extension/manifest.json`
- `tests/firefox_dom_harness.mjs`
- Protocol fixture files if needed

Exit condition: every Wave 1 agent can implement against stable interfaces without editing shared files.

### Wave 1A — DOM identity and traversal (Luna A)

Owns:

- `firefox_dom/extension/content/dom-core.js`
- `tests/firefox_dom_core_test.mjs`

Implements:

- Document identity
- Stable node registry
- Reverse lookup and lifecycle checks
- Composed-tree traversal
- Open shadow roots and slots
- Direct-text extraction
- Mutation revision and bounded ring buffer
- Shared redaction and budget primitives

Must not implement query syntax, output views, actions, background routing, or Lua.

### Wave 1B — DOM search (Luna B)

Owns:

- `firefox_dom/extension/content/dom-query.js`
- `tests/firefox_dom_query_test.mjs`

Implements:

- Bounded CSS search across open roots
- Structured predicates
- Within/ancestor/descendant scoping
- Text, attribute, state, and rectangle predicates
- Invalid-selector and truncation behavior
- Compact match descriptions through the frozen core/view interfaces

Uses mocked core interfaces until integration.

### Wave 1C — outlines and inspection (Luna C)

Owns:

- `firefox_dom/extension/content/dom-view.js`
- `tests/firefox_dom_view_test.mjs`

Implements:

- Node descriptions at outline and inspect detail levels
- Hierarchical pruning and wrapper collapse
- Ancestor/context retention
- Region, focused, viewport, document, and subtree scopes
- Relationship resolution
- Geometry, visibility, hit-test, and interaction hints
- Truncation and continuation metadata

Uses mocked core interfaces until integration.

### Wave 1D — node actions (Luna D)

Owns:

- `firefox_dom/extension/content/dom-actions.js`
- `tests/firefox_dom_actions_test.mjs`

Implements:

- Node validation
- Click, focus, type, set-value, select, press, scrolling, check, uncheck, and submit
- Native property setters and event ordering
- Native select ambiguity handling
- Focus and target state before/after
- Visibility and center hit-test checks
- Optional settled mutation summary through the frozen core API

Documents synthetic-event limitations in test names and errors.

### Wave 1E — background and native transport (Luna E)

Owns:

- `firefox_dom/extension/background.js`
- `firefox_dom/bridge/Cargo.toml`
- `firefox_dom/bridge/Cargo.lock`
- `firefox_dom/bridge/src/main.rs`
- `tests/firefox_dom_background_test.mjs`

Implements:

- Native host connection
- Tab/frame routing and aggregation
- External ref prefixing/parsing
- Sequential mutation guard
- Navigation and tab operations
- Structured inaccessible-frame reporting
- Rust socket/native-message transport with size limits and timeouts

Does not edit content modules or manifest.

### Wave 1F — Lua surface and setup (Luna F)

Owns:

- `tools/firefox_dom.lua`
- `commands/firefox_dom.lua`
- `firefox_dom/setup.sh`
- `firefox_dom/README.md`
- `tests/firefox_dom_tool_test.lua`

Implements:

- Complete strict Lua schema
- Local bridge invocation
- Setup, doctor, and remove
- Separate state/socket/native-host identities
- User documentation, security disclosure, and limitations
- Schema regression tests

Does not edit catalog generation or extension implementation.

### Wave 2 — integration and end-to-end tests (one integration agent)

Owns shared wiring and integration-only files:

- `firefox_dom/extension/content/content-main.js`
- `firefox_dom/extension/manifest.json`
- `tests/firefox_dom_extension_test.mjs`
- Necessary narrow fixes across Wave 1 files after reporting conflicts

Tasks:

- Wire namespace modules in manifest order.
- Route content requests to core/query/view/actions.
- Reconcile module assumptions without redesigning contracts.
- Add end-to-end Chase-like custom dropdown coverage.
- Add native select, shadow root, slot, frame, mutation, large-page truncation, detached-node, and redaction coverage.
- Verify no source or runtime identity overlaps the current Firefox tool.

The integration agent must report any cross-module contract changes explicitly.

### Wave 3 — parallel review

Run three read-only Luna reviewers in parallel:

1. **Correctness reviewer**
   - Node lifetime, traversal duplication, frame routing, refs, action behavior, mutation revisions.
2. **Security/privacy reviewer**
   - Redaction, URL handling, arbitrary-code paths, native host permissions, message bounds, setup/removal safety.
3. **Performance/context reviewer**
   - Large DOM traversal, repeated layout reads, mutation pressure, output budgets, pruning quality, JSON size.

Reviewers report only verified significant issues with file/line references and concrete fixes. The lead applies fixes serially.

### Wave 4 — packaging and final validation (lead, serial)

Only after implementation and reviews pass:

- Add the new command-owned bundle to `gen-index.sh` without modifying the existing browser bundle behavior.
- Regenerate `catalog.json`.
- Build `bone-firefox-dom-0.1.0.zip` from the new extension only.
- Verify every catalog hash and ZIP member byte-for-byte.
- Preserve all unrelated working-tree changes.

## Suggested Luna dispatch prompts

Each task prompt should include:

- Repository path: `/home/vincent/projects/bone-catalog`
- This plan's goal, non-goals, protocol, and module interface sections
- Exact owned files
- Explicit forbidden files
- Required tests and validation
- Output format: summary, changed files, tests, assumptions, unresolved issues

Do not ask multiple agents to “implement the extension” broadly. Dispatch Wave 1A–1F together only after Wave 0 contracts exist.

## Required regression coverage

- Unlabelled focusable/clickable `<div>` is findable and inspectable.
- Wrapper-heavy DOM is pruned in outline but every wrapper remains findable.
- Direct text is not repeated on all ancestors.
- Chase-like custom dropdown exposes control, popup mutation, and options.
- Native select exposes bounded options and selects by exact label/value/index.
- ARIA combobox exposes controlled node and active descendant.
- Nested open shadow roots and slots have correct hierarchy without duplicates.
- Separate same-origin and cross-origin-accessible frames retain frame identity.
- Hidden elements are findable only when requested and cannot be clicked accidentally.
- Covered elements report the covering node.
- Focus before/after is correct.
- Password, hidden, token-like, script, and style content is redacted or omitted.
- Detached and stale-document refs fail deterministically.
- Mutation summaries coalesce updates and expire old revisions explicitly.
- Node/text/attribute/option/search limits always hold.
- A synthetic canceled keydown does not trigger manual default behavior.
- Large virtualized lists remain bounded while new nodes appear after scrolling.

## Validation matrix

Run from `/home/vincent/projects/bone-catalog`:

```bash
node --check firefox_dom/extension/background.js
node --check firefox_dom/extension/content/namespace.js
node --check firefox_dom/extension/content/dom-core.js
node --check firefox_dom/extension/content/dom-query.js
node --check firefox_dom/extension/content/dom-view.js
node --check firefox_dom/extension/content/dom-actions.js
node --check firefox_dom/extension/content/content-main.js
node --test tests/firefox_dom_*_test.mjs
lua tests/firefox_dom_tool_test.lua
lua -e 'assert(loadfile("tools/firefox_dom.lua")); assert(loadfile("commands/firefox_dom.lua"))'
bash -n firefox_dom/setup.sh gen-index.sh
cargo fmt --check --manifest-path firefox_dom/bridge/Cargo.toml
cargo test --locked --manifest-path firefox_dom/bridge/Cargo.toml
git diff --check
```

Also run a large synthetic-DOM benchmark and record:

- Total elements
- Outline nodes returned
- Serialized response bytes
- Traversal time
- Layout-read count if instrumented
- Mutation processing time

Initial performance targets on a 10,000-element synthetic page:

- Default viewport outline under 100 ms after content-script warmup
- Search under 150 ms for ordinary selectors/predicates
- Response under 256 KiB at default budgets
- No unbounded mutation queue growth

These are engineering targets, not protocol guarantees; tests should avoid flaky wall-clock assertions.

## Manual acceptance scenarios

Before release, exercise in normal Firefox:

1. Ordinary form with input, checkbox, native select, and submit.
2. Chase-like transaction filter with unnamed custom dropdown.
3. Open-shadow-root component with slotted options.
4. Long virtualized list inside a scroll container.
5. Modal overlay covering controls beneath it.
6. Page containing password and token-like fields.
7. Navigation that replaces the document and invalidates old refs.

For each scenario, save the exact tool-call sequence and confirm that no full HTML or unbounded text appears.

## Definition of done

- New tool, extension, host, setup command, tests, package, and catalog entry exist under independent identities.
- All required automated and manual scenarios pass.
- Three Wave 3 reviews have no unresolved significant findings.
- Context and performance budgets are measured and enforced.
- Package contents and catalog hashes are verified.
- Existing `firefox` tool behavior and files are unchanged.
- README states DOM coverage, sensitive-data exposure, synthetic-input limitations, inaccessible surfaces, and removal steps.
