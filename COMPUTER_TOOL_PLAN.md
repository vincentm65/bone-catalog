# Computer Tool Improvement Plan

This roadmap covers `tools/computer.lua`, `scripts/computer_atspi.py`,
`tests/computer_test.lua`, and the Hyprland computer-tool documentation in
`README.md`. Work is ordered by risk: make input safe and deterministic first,
then improve targeting and diagnostics, and optimize only after measurements
exist.

Current status: the reliability, semantic, tracing, and low-risk speed changes
are implemented directly in the primary `main` checkouts, with no auxiliary
worktree. The full Bone workspace suite, the catalog Lua/Python suites, and the
2,160-point geometry suite are green; live desktop integration, long-running
metrics, and rollout validation remain.

In this checklist, `[x]` means the implementation exists in the primary
checkout. Release gates remain unchecked until their complete test targets have
passed; a checked implementation item does not by itself claim that a release
gate is satisfied.

## 0. First delivery: AT-SPI correctness and privacy

- [x] Add Python unit tests for `scripts/computer_atspi.py` using fake accessible
  trees plus real GI enum names when GI is available.
- [x] Fix `enum_key()` so it removes the exact `ATSPI_ROLE_` prefix and preserves
  complete multiword roles.
- [x] Add table-driven coverage for every supported role, including
  `PASSWORD_TEXT` and other multiword roles.
- [x] Ensure password controls never expose their accessible name; emit
  `[protected]` consistently in discovery and resolution, and never query their
  value.
- [x] Exclude disabled, insensitive, invisible, and non-showing controls from
  actionable semantic results.
- [x] Integrate privacy-safe rejected-candidate counters into the
  structured trace itself.
  - [x] Return bounded rejection counters, nodes visited/matched, and truncation
    in `semantic_find` results.
  - [x] Copy those semantic counters into the opt-in trace record.
- [x] Add the Python test suite to CI alongside `tests/computer_test.lua`.

Exit criteria:

- [x] All supported roles round-trip from GI enum names correctly.
- [x] Password-name redaction and the no-value-query contract have explicit
  regression coverage.
- [x] No disabled or non-visible semantic target is reported as actionable.

## 1. Input correctness, freshness, and idempotency

- [x] Validate the entire request before capture or input: all coordinates,
  `settle_ms`, `duration_ms`, scroll amount, text limits, keys, semantic IDs,
  target labels, and action-specific fields.
- [x] Split visual identity from input authorization:
  - [x] Keep an image/content ID for screenshot reuse.
  - [x] Issue a new single-use action token after every successful observation.
  - [x] Require the same `{screenshot_id, action_token}` pair for every
    non-observe action, including read-only continuation actions, so the schema
    has one predictable contract and successful calls always rotate the pair.
  - [x] Consume the action token before input, even when the post-action pixels
    are unchanged.
- [x] Use the host-supplied `call_id` for mutating actions and record a bounded
  outcome ledger in state.
  - [x] A repeated completed `call_id` returns the recorded outcome.
  - [x] A repeated in-flight or ambiguous `call_id` never sends input again.
  - [x] Reject reuse of a `call_id` with different parameters.
- [x] Apply conservative authorization semantics at cancellation and
  persistence boundaries.
  - [x] Block authorization after uncertain delivery, input execution failure,
    failed post-action capture, or failed response persistence, and require
    `computer_observe` to recover.
  - [x] Verify that cancellation before reservation sends no input and preserves
    the unused authorization, while cancellation after input blocks and requires
    observation recovery.
  - [x] Fail a reservation write before input and treat a post-input persistence
    failure as ambiguous without retrying delivery.
  - [x] Prepare all read-only response artifacts before committing a rotated
    pair, so presentation/encoding failure leaves the caller's prior pair
    usable.
- [x] Bind a completed ledger replay's returned continuation to its exact
  resulting operation generation; never expose an unrelated later token merely
  because identical pixels reused the same screenshot ID.
- [x] Reject ambiguous multiple Hyprland instances rather than choosing the first
  discovered signature.
- [x] Store only a minimal hashed window/context fingerprint in state; never
  persist raw titles, classes, typed text, or accessibility names.
- [x] Use monotonic elapsed time for screenshot/action TTL checks.
- [x] Preserve the contract that an input command is sent at most once and is
  never automatically retried.

Exit criteria:

- [x] Covered completed and ambiguous `call_id` replay tests produce zero
  duplicate input events.
- [x] Identical post-action screenshots still receive a fresh, single-use action
  token.
- [x] Every tested ambiguous delivery path blocks further input until a new
  observation, while proven-not-delivered spawn failures remain separately
  classified and never replay input.

## 2. Stable observation and race-resistant actions

- [x] Implement one stable-observation helper in `tools/computer.lua`:
  1. Read monitor, workspace, focused-window, and Hyprland-instance metadata.
  2. Capture pixels.
  3. Read the same metadata again.
  4. Accept only when identity, workspace, focus, geometry, transform, and scale
     match before and after capture.
- [x] Use that helper for `computer_observe`, pre-action capture, and post-action
  capture.
- [x] Immediately before coordinate input, compare a target-region/tile
  fingerprint against the referenced observation.
- [x] Extend fresh-pixel checks from `click_locked` to ordinary click,
  double-click, right-click, drag endpoints, scroll anchors, move, and
  coordinate actions; typing uses a separate accessible-focus check.
- [x] Make target-region comparison tolerant of unrelated animation elsewhere on
  the monitor while remaining strict at the intended target tile.
- [x] After `ydotool mousemove`, read back the actual pointer position and verify
  it is within the logical-pixel tolerance before clicking.
- [x] After input, perform a stable observation but never retry input because
  observation or verification failed.
- [ ] Add action-specific verification where observable:
  - [x] Pointer position after move.
  - [x] Accessible focus before typing.
  - [ ] Accessible state transition after semantic activation.
  - [ ] Scroll displacement or changed target-region evidence.
- [x] Treat compositor restarts, focus changes, workspace switches, output
  hotplug, and monitor geometry changes as explicit freshness failures.

Exit criteria:

- [x] Zero pointer or input events cross 1,000 injected target-tile
  perception/action races.
- [x] Coordinate conversion is within one logical pixel across 2,160 checked
  points covering every supported transform, fractional scale, and monitor
  origin.
- [x] A failed or unstable post-action observation never causes a second input
  in the expanded Lua regression suite.

## 3. Semantic targeting accuracy

- [x] Replace fragile child-index-only resolution with an opaque semantic
  fingerprint containing role, protected name digest, action metadata,
  application/window identity, and nearby hierarchy. Bounds remain live
  verification data rather than fingerprint identity so layout changes do not
  make a control stale.
- [ ] Complete screen-space intersection/hit testing for semantic fallback.
  - [x] Re-resolve by fingerprint immediately before activation, validate live
    bounds against the focused window, and reject fingerprint collisions.
  - [ ] Add explicit overlapping-control/hit-test rejection for coordinate
    fallback.
- [x] Invoke the verified AT-SPI action for semantic activation when available;
  retain coordinate clicking as an explicit fallback.
- [x] Stop requiring exact equality for transient semantic states that do not
  affect identity or actionability.
- [x] Extend `semantic_find` with bounded filters:
  - [x] `query`
  - [x] `roles`
  - [x] `near`
  - [x] `max_results`
- [x] Rank enabled, visible, named, actionable controls ahead of structural or
  unnamed nodes and report truncation.
- [x] Verify the focused accessible control before sensitive typing.
  - [x] Query at most three focused nodes through the selected window's AT-SPI
    Collection interface, validate each result back to that root, reject
    ambiguity, and retain the bounded tree walk only as a compatibility
    fallback.
  - [x] Treat a focused, editable combo box as typing-safe; Firefox exposes its
    address bar with that role rather than as a plain entry.
- [x] Return stable reason codes for rejected, ambiguous, stale, protected, and
  unavailable targets.

Exit criteria:

- [ ] Deterministic GTK and browser fixtures select the intended control across
  layout changes that preserve semantic identity.
- [x] Ambiguous semantic matches send no input in deterministic helper fixtures.
- [x] The separate coordinate-action path remains available when AT-SPI is
  unavailable, and AT-SPI-capable controls explicitly report whether semantic
  activation or freshly resolved coordinate fallback was used.

## 4. Structured debugging and inline failures

- [x] Add opt-in structured tracing keyed by `operation_id` and `call_id`.
- [ ] Finish the complete trace field set.
  - [x] Record stages, elapsed time, terminal reason code, subprocess count,
    dependency exit category, and requested versus actual pointer coordinates.
  - [x] Add monitor/context fingerprint, capture dimensions/bytes/hashes, diff
    regions, and AT-SPI traversal counters to the trace object.
  - [x] Return a privacy-safe terminal trace for runtime rejections after trace
    initialization.
  - [ ] Initialize tracing early enough to cover malformed-request and stale-ID
    failures that currently reject before operation setup.
- [x] Keep trace records privacy-safe by default: no raw titles, typed text,
  command arguments, accessibility names/values, or screenshots.
- [ ] Support an explicit local trace bundle with `0600` permissions, bounded
  size, automatic expiry, and a manifest of sanitized environment/dependency
  versions.
- [x] Keep diagnostics on the existing `computer_observe` and `computer` tools
  instead of registering a separate diagnostic schema and paying for an extra
  tool call.
- [x] Reject a selected output whose Hyprland `dpmsStatus` is false before
  spawning `grim`, with stable `output_dpms_off` classification and an
  instruction not to retry until the display is awake.
- [x] Document stable reason-code categories and a minimal privacy-safe
  bug-report workflow.

Exit criteria:

- [ ] Every action reports stage timings and a stable terminal reason code when
  tracing is enabled.
- [ ] A trace can explain stale/ambiguous failures without exposing protected
  user content.
- [x] A sleeping display is identified by the ordinary observation call without
  waiting for the screenshot timeout or registering another tool.

## 5. Performance and native-backend path

Instrument first; optimize against P50/P95 data rather than estimates.

- [ ] Complete per-stage baselines for observe, click, semantic find, and type,
  including process count, capture size, copied bytes, and encoded bytes.
  - [x] Assert the native cached-observe and stable-click process counts and
    record capture byte/hash metadata in traces.
  - [ ] Add dedicated semantic-find/type latency and byte baselines.
- [x] Cache a confirmed Hyprland instance signature and rediscover only after IPC
  failure or an explicit instance-change signal.
- [x] Use the Bone native cancellable timer when available, with a bounded
  compatibility fallback.
- [x] Resize the model-sized overview in-process with native bounded PNG resize,
  while retaining an ImageMagick fallback for older Bone builds. The full clean
  capture remains available for validation.
- [x] Replace disk-backed two-pass ImageMagick differences with a binary-safe
  in-memory PNG difference plus native tile fingerprints.
- [x] Hash exact target-lock regions in-process with native
  `png_region_sha256`, retaining the older-Bone ImageMagick crop/hash fallback.
- [x] Avoid the ordinary 512-node accessibility walk during typing-focus checks
  when AT-SPI Collection is available by querying no more than three focused
  controls and failing closed on ambiguity.
- [ ] Keep the AT-SPI bridge persistent so Python/GI startup is not paid on every
  semantic call.
- [ ] Compact repeated response instructions and avoid serializing unchanged
  semantic state.
- [ ] Add binary image/blob handles across the Bone runtime so PNG data does not
  repeatedly pass through Lua strings, base64 JSON, Rust UTF-8 strings, and data
  URLs.
- [ ] Move capture, diff, coordinate mapping, stable observation, and input
  authorization into a native backend; keep `tools/computer.lua` as the catalog
  schema/orchestration layer.
- [x] Track cross-repository runtime work separately when it belongs in Bone core
  (for example binary-safe process output and blob handles) rather than hiding it
  in catalog code.

Performance targets:

- [x] Current measured native fast path: at most 4 subprocesses for a cached
  observation and 10 for a stable coordinate click (9 when the inherited
  Hyprland signature matches the cache), with no external `sleep` or
  ImageMagick process.
- [ ] Original interim goal: reduce a stable normal click from the current
  tested ceiling of 10 to no more than 6 subprocesses without weakening the two
  stable captures or pointer verification.
- [ ] Native backend: no more than 2 subprocesses for a normal click.
- [ ] Set observe/click P50 and P95 latency budgets after the first instrumented
  baseline, then fail performance regression checks above an agreed tolerance.

## 6. Tests, documentation, and rollout

- [ ] Finish the full `tests/computer_test.lua` matrix.
  - [x] Add coverage for single-use tokens, `call_id` replay, unchanged pixels,
    ambiguity/not-delivered classification and recovery, state privacy, target
    locks, inline DPMS rejection, trace fields, 1,000 target-tile races, and
    native fast-path process ceilings.
  - [x] Add pre/post-reservation cancellation, native resize/region hashing, and
    older-Bone compatibility fallback coverage.
  - [x] Keep the expanded Lua suite green.
  - [ ] Complete remaining cleanup, state-write failure, realistic-PNG, and
    broader compositor/input fault-injection cases.
- [x] Add Python tests for fake AT-SPI trees and real GI enum behavior.
- [x] Add property tests for all Hyprland transforms (`0`–`7`), fractional scales,
  negative origins, monitor edges, mixed-DPI layouts, and workspace transitions.
- [ ] Add a nested headless Hyprland integration environment with deterministic
  GTK and browser fixtures.
- [ ] Add fault injection for focus races, animation, compositor restart, output
  changes, partial typing, stuck drag buttons, unavailable `ydotoold`, and
  concurrent sessions.
- [ ] Add a nightly model-in-the-loop task corpus with exact success, duplicate
  input, stale action, latency, and process-count metrics.
- [x] Finish the current README rollout documentation.
  - [x] Document PNG output, normalized `0`–`1` coordinates, the split
    `computer_observe`/`computer` API, action-token freshness, semantic behavior,
    recovery rules, sanitized tracing, and native-helper feature detection.
  - [x] Document inline DPMS-off rejection and the two-tool diagnostic workflow.
  - [x] Document the bounded Collection focus query and why raw `wtype` or a
    long-lived `wl-copy` process is not an automatic safe-typing fallback.
  - [x] Distinguish `not_sent`, proven `not_delivered`, and
    `sent_unverified`/ambiguous recovery.
- [x] Roll out state safety changes behind an explicit state-version boundary
  when the schema changes.
- [x] Require a fresh `computer_observe` when migrating old state to the new
  authorization format.

Release gates:

- [x] Zero duplicated inputs in replay/idempotency tests.
- [x] Zero stale inputs across 1,000 injected target-tile race iterations.
- [x] At most one logical-pixel coordinate error across 2,160 transform/scale
  test points.
- [x] Complete password-name/value redaction.
- [ ] 100% Unicode typing fidelity for the supported input path.
- [x] No sensitive values in default state, logs, errors, or traces in the
  privacy regression coverage.
- [ ] Observe and click P50/P95 stay within the budgets established from the
  instrumented baseline.

## Delivery sequence

Delivery now uses the primary `main` checkouts directly; these are implementation
slices, not worktree or PR branches.

- [x] Slice 1 — AT-SPI enum correctness, password redaction, actionability
  filtering, Python tests, and CI.
- [x] Slice 2 — Single-use action tokens, host `call_id` idempotency, complete
  preflight validation, and ambiguous-delivery blocking.
  - [x] Implementation is present.
  - [x] Expanded Lua replay, ambiguity, not-delivered, and pre/post-cancellation
    tests are green.
- [ ] Slice 3 — Stable observation transaction, target-region freshness, cursor
  readback, transform property tests, and race fault injection.
  - [x] Runtime path, 2,160-point geometry suite, and 1,000 target-tile race
    suite are green.
  - [ ] Broader compositor/output/focus fault-injection infrastructure remains.
- [ ] Slice 4 — Semantic fingerprints, direct AT-SPI invocation,
  filtered/ranked discovery, and deterministic UI fixtures.
  - [x] Runtime and Python unit-test implementation is present.
  - [ ] Deterministic GTK/browser integration fixtures remain.
- [ ] Slice 5 — Structured traces, stable reason codes, inline failures, and
  debugging documentation.
  - [x] Privacy-safe in-memory tracing, expanded evidence fields, runtime
    rejection traces, reason categories, DPMS preflight, and README workflow
    are present.
  - [ ] Earlier validation-error tracing and the persistent trace bundle remain.
- [ ] Slice 6 — Instrumented process/latency baseline and low-risk
  process/capture optimizations.
  - [x] Signature caching, native wait feature detection, and in-memory native
    PNG resize/tile/region/diff paths are present with compatibility fallbacks.
  - [x] Cached observe `<=4` and stable coordinate click `<=10` (`9` with a
    matching inherited signature) subprocess regression ceilings are asserted
    without external sleep/ImageMagick.
  - [ ] Semantic/type baselines, latency budgets, the original click `<=6`
    optimization goal, and direct model-sized capture remain.
- [ ] Slice 7 — Bone-core binary/blob support and the native computer backend.
  - [x] Native time/random/PNG resize/tile/region/diff helper work is tracked
    and feature-detected.
  - [ ] Blob handles, a persistent AT-SPI service, and the native backend remain.
