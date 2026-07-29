# Computer Tool Improvement Plan

This roadmap covers `tools/computer.lua`, `scripts/computer_atspi.py`,
`tests/computer_test.lua`, and the Hyprland computer-tool documentation in
`README.md`. Work is ordered by risk: make input safe and deterministic first,
then improve targeting and diagnostics, and optimize only after measurements
exist.

Current status: the first delivery is implemented on
`codex/computer-tool-first-pass` and is pending review/merge.

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
- [ ] Add privacy-safe rejected-candidate reason counters to structured tracing
  when that tracing is implemented.
- [x] Add the Python test suite to CI alongside `tests/computer_test.lua`.

Exit criteria:

- [x] All supported roles round-trip from GI enum names correctly.
- [x] Password-name redaction and the no-value-query contract have explicit
  regression coverage.
- [x] No disabled or non-visible semantic target is reported as actionable.

## 1. Input correctness, freshness, and idempotency

- [ ] Validate the entire request before capture or input: all coordinates,
  `settle_ms`, `duration_ms`, scroll amount, text limits, keys, semantic IDs,
  target labels, and action-specific fields.
- [ ] Split visual identity from input authorization:
  - [ ] Keep an image/content ID for screenshot reuse.
  - [ ] Issue a new single-use action token after every successful observation.
  - [ ] Consume the action token before input, even when the post-action pixels
    are unchanged.
- [ ] Add a caller-supplied `call_id` to mutating actions and record a bounded
  outcome ledger in state.
  - [ ] A repeated completed `call_id` returns the recorded outcome.
  - [ ] A repeated in-flight or ambiguous `call_id` never sends input again.
  - [ ] Reject reuse of a `call_id` with different parameters.
- [ ] Invalidate action authorization after cancellation, response failure,
  compositor instability, uncertain delivery, or a failed post-action capture;
  require `computer_observe` to recover.
- [ ] Reject ambiguous multiple Hyprland instances rather than choosing the first
  discovered signature.
- [ ] Store only a minimal hashed window/context fingerprint in state; never
  persist raw titles, classes, typed text, or accessibility names.
- [ ] Use monotonic elapsed time for screenshot/action TTL checks.
- [ ] Preserve the contract that an input command is sent at most once and is
  never automatically retried.

Exit criteria:

- [ ] Replay tests produce zero duplicate input events.
- [ ] Identical post-action screenshots still receive a fresh, single-use action
  token.
- [ ] Every ambiguous delivery path blocks further input until a new observation.

## 2. Stable observation and race-resistant actions

- [ ] Implement one stable-observation helper in `tools/computer.lua`:
  1. Read monitor, workspace, focused-window, and Hyprland-instance metadata.
  2. Capture pixels.
  3. Read the same metadata again.
  4. Accept only when identity, workspace, focus, geometry, transform, and scale
     match before and after capture.
- [ ] Use that helper for `computer_observe`, pre-action capture, and post-action
  capture.
- [ ] Immediately before coordinate input, compare a target-region/tile
  fingerprint against the referenced observation.
- [ ] Extend fresh-pixel checks from `click_locked` to ordinary click,
  double-click, right-click, drag endpoints, scroll anchors, move, and
  coordinate-derived typing focus.
- [ ] Make target-region comparison tolerant of unrelated animation elsewhere on
  the monitor while remaining strict at the intended target.
- [ ] After `ydotool mousemove`, read back the actual pointer position and verify
  it is within the logical-pixel tolerance before clicking.
- [ ] After input, perform a stable observation but never retry input because
  observation or verification failed.
- [ ] Add action-specific verification where observable:
  - [ ] Pointer position after move.
  - [ ] Accessible focus before typing.
  - [ ] Accessible state transition after semantic activation.
  - [ ] Scroll displacement or changed target-region evidence.
- [ ] Treat compositor restarts, focus changes, workspace switches, output
  hotplug, and monitor geometry changes as explicit freshness failures.

Exit criteria:

- [ ] Zero input events cross 1,000 injected perception/action races.
- [ ] Coordinate conversion is within one logical pixel for every supported
  transform, fractional scale, and monitor origin.
- [ ] A failed or unstable post-action observation never causes a second input.

## 3. Semantic targeting accuracy

- [ ] Replace fragile child-index-only resolution with a stable semantic
  fingerprint containing role, protected name digest, bounds, action metadata,
  application/window identity, and nearby hierarchy.
- [ ] Re-resolve candidates immediately before activation and use screen-space
  intersection/hit testing to reject ambiguous matches.
- [ ] Invoke the verified AT-SPI action for semantic activation when available;
  retain coordinate clicking as an explicit fallback.
- [ ] Stop requiring exact equality for transient semantic states that do not
  affect identity or actionability.
- [ ] Extend `semantic_find` with bounded filters:
  - [ ] `query`
  - [ ] `roles`
  - [ ] `near`
  - [ ] `max_results`
- [ ] Rank enabled, visible, named, actionable controls ahead of structural or
  unnamed nodes and report truncation.
- [ ] Verify the focused accessible control before sensitive typing.
- [ ] Return stable reason codes for rejected, ambiguous, stale, protected, and
  unavailable targets.

Exit criteria:

- [ ] Deterministic GTK and browser fixtures select the intended control across
  layout changes that preserve semantic identity.
- [ ] Ambiguous semantic matches send no input.
- [ ] Coordinate fallback remains available and clearly identified when AT-SPI is
  unavailable.

## 4. Structured debugging and `computer_doctor`

- [ ] Add opt-in structured tracing keyed by `operation_id` and `call_id`.
- [ ] Record stage start/end, elapsed time, reason/error code, subprocess count,
  dependency exit category, monitor/context fingerprint, requested versus actual
  pointer coordinates, capture dimensions/bytes/hashes, diff regions, and AT-SPI
  nodes visited/matched/truncated/rejected.
- [ ] Keep trace records privacy-safe by default: no raw titles, typed text,
  command arguments, accessibility names/values, or screenshots.
- [ ] Support an explicit local trace bundle with `0600` permissions, bounded
  size, automatic expiry, and a manifest of sanitized environment/dependency
  versions.
- [ ] Add a read-only `computer_doctor` action/tool that checks:
  - [ ] Hyprland discovery and ambiguity.
  - [ ] `hyprctl` monitor/workspace/client queries.
  - [ ] `grim` geometry and PNG validity.
  - [ ] Output transforms, scale, and cursor calibration.
  - [ ] ImageMagick availability while it remains required.
  - [ ] `ydotool`/`ydotoold` socket connectivity without emitting input.
  - [ ] Python, GI, and AT-SPI availability and versions.
- [ ] Document stable reason codes and a minimal bug-report workflow.

Exit criteria:

- [ ] Every action reports stage timings and a stable terminal reason code when
  tracing is enabled.
- [ ] A trace can explain stale/ambiguous failures without exposing protected
  user content.
- [ ] `computer_doctor` distinguishes missing dependency, permission, session,
  geometry, and daemon/socket failures.

## 5. Performance and native-backend path

Instrument first; optimize against P50/P95 data rather than estimates.

- [ ] Establish per-stage baselines for observe, click, semantic find, and type,
  including process count, capture size, copied bytes, and encoded bytes.
- [ ] Cache a confirmed Hyprland instance signature and rediscover only after IPC
  failure or an explicit instance-change signal.
- [ ] Replace external `sleep` invocations with a native cancellable timer.
- [ ] Capture or encode the model-sized overview directly when a native-resolution
  image is not required for target validation.
- [ ] Replace disk-backed two-pass ImageMagick diffs with one binary-safe
  in-memory target-region/tile diff.
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
- [ ] Track cross-repository runtime work separately when it belongs in Bone core
  (for example binary-safe process output and blob handles) rather than hiding it
  in catalog code.

Performance targets:

- [ ] Interim Lua implementation: no more than 6 subprocesses for a normal click.
- [ ] Native backend: no more than 2 subprocesses for a normal click.
- [ ] Set observe/click P50 and P95 latency budgets after the first instrumented
  baseline, then fail performance regression checks above an agreed tolerance.

## 6. Tests, documentation, and rollout

- [ ] Expand `tests/computer_test.lua` with valid PNG fixtures, realistic JSON,
  state corruption, single-use tokens, `call_id` replay, unchanged pixels,
  ambiguity, cancellation, privacy, cleanup, resize, lock, and diff cases.
- [ ] Add Python tests for fake AT-SPI trees and real GI enum behavior.
- [ ] Add property tests for all Hyprland transforms (`0`–`7`), fractional scales,
  negative origins, monitor edges, mixed-DPI layouts, and workspace transitions.
- [ ] Add a nested headless Hyprland integration environment with deterministic
  GTK and browser fixtures.
- [ ] Add fault injection for focus races, animation, compositor restart, output
  changes, partial typing, stuck drag buttons, unavailable `ydotoold`, and
  concurrent sessions.
- [ ] Add a nightly model-in-the-loop task corpus with exact success, duplicate
  input, stale action, latency, and process-count metrics.
- [ ] Correct `README.md` to describe PNG output, normalized `0`–`1` coordinates,
  the split `computer_observe`/`computer` API, action-token freshness, semantic
  behavior, recovery rules, and `computer_doctor`.
- [ ] Roll out safety changes behind a compatibility/version boundary if state or
  schema changes would make existing callers unsafe.
- [ ] Require a fresh `computer_observe` when migrating old state to the new
  authorization format.

Release gates:

- [ ] Zero duplicated inputs in replay/idempotency tests.
- [ ] Zero stale inputs across 1,000 injected race iterations.
- [ ] At most one logical-pixel coordinate error across transform/scale tests.
- [ ] Complete password-name/value redaction.
- [ ] 100% Unicode typing fidelity for the supported input path.
- [ ] No sensitive values in default state, logs, errors, or traces.
- [ ] Observe and click P50/P95 stay within the budgets established from the
  instrumented baseline.

## Delivery sequence

- [ ] PR 1 — AT-SPI enum correctness, password redaction, actionability filtering,
  Python tests, and CI.
- [ ] PR 2 — Single-use action tokens, `call_id` idempotency, complete preflight
  validation, ambiguous-delivery invalidation, and tests.
- [ ] PR 3 — Stable observation transaction, target-region freshness, cursor
  readback, transform property tests, and race fault injection.
- [ ] PR 4 — Semantic fingerprints, AT-SPI invocation, filtered/ranked discovery,
  and deterministic UI fixtures.
- [ ] PR 5 — Structured traces, stable reason codes, `computer_doctor`, and
  debugging documentation.
- [ ] PR 6 — Instrumented process/latency baseline and low-risk process/capture
  optimizations.
- [ ] PR 7 — Bone-core binary/blob support and the native computer backend,
  delivered behind compatibility tests and the measurable release gates above.
