# Strict Screenshot Workflow Plan

This plan covers `tools/computer.lua`, `tests/computer_test.lua`, generated
catalog metadata, and the Hyprland documentation in `README.md`.

Current status: the runtime and Lua regression suite implement a strict
observation plus click/type workflow. Automated release validation is complete;
a manual live Hyprland check remains.

In this checklist, `[x]` means the implementation exists in the primary
checkout. Unchecked items are release gates, not alternate API work.

## 1. Public API boundary

- [x] Register `computer_observe` as the observation-only entry point.
- [x] Limit its optional schema fields to `monitor`, `grid`, and `trace`.
- [x] Limit `computer` to exactly `action="click"` and `action="type"`.
- [x] Require `action`, `screenshot_id`, and `action_token` on every `computer`
  call.
- [x] Limit common continuation fields to `settle_ms`, `grid`, and `trace`.
- [x] Limit click-specific fields to `x`, `y`, and `target_label`.
- [x] Limit type-specific fields to `text`.
- [x] Reject unknown and action-irrelevant fields before capture or input.
- [x] Keep normalized click coordinates bound to the referenced full-monitor
  screenshot.
- [x] Return a replacement `screenshot_id`/`action_token` pair after every
  successful call.

## 2. Authorization, freshness, and idempotency

- [x] Validate all fields before capture, reservation, or input.
- [x] Validate normalized click coordinates, bounded text, `settle_ms`,
  `target_label`, `grid`, and `trace`.
- [x] Separate visual identity from input authorization:
  - [x] Reuse `screenshot_id` only when clean captured pixels are identical.
  - [x] Issue a fresh single-use token after every successful observation.
  - [x] Require the exact current pair for every click and type action.
  - [x] Consume authorization before input, including when later pixels are
    unchanged.
- [x] Use the host-supplied `call_id` for input actions and record a bounded
  outcome ledger.
  - [x] Return the recorded outcome for a repeated completed call.
  - [x] Send no input for a repeated in-flight or ambiguous call.
  - [x] Reject a reused `call_id` when its parameters differ.
- [x] Preserve response and persistence atomicity.
  - [x] Prepare presentation data before committing an observation pair.
  - [x] Reserve and persist the input outcome at the delivery boundary.
  - [x] Never expose an unpersisted continuation pair.
- [x] Distinguish `not_sent`, proven `not_delivered`, and `sent_unverified`.
- [x] Return `retry_input=false` and `computer_observe` recovery after failures.
- [x] Bind completed replay continuation data to the exact resulting operation
  generation, even when later identical pixels reuse the screenshot ID.
- [x] Reject ambiguous multiple Hyprland instances instead of guessing.
- [x] Store only minimal salted context and image fingerprints, never raw titles,
  classes, typed text, or screenshot bytes.
- [x] Use monotonic elapsed time for freshness checks.
- [x] Send an input command at most once and never retry it automatically.

## 3. Stable observation and race resistance

- [x] Use one stable-observation transaction for initial, pre-input, and
  post-input captures:
  1. Read monitor, workspace, focused-window, and instance metadata.
  2. Capture the selected monitor.
  3. Read the same metadata again.
  4. Accept only when identity, focus, geometry, transform, and scale match.
- [x] Reject a selected output with DPMS disabled before starting capture.
- [x] Validate PNG structure, dimensions, and monitor geometry before encoding or
  persistence.
- [x] Build tile fingerprints from the clean capture.
- [x] Compare the click target tile immediately before input while tolerating
  unrelated changes elsewhere on the monitor.
- [x] Convert normalized screenshot points across every Hyprland transform,
  fractional scale, and monitor origin.
- [x] Position the cursor through Hyprland, read it back, and require one-logical-
  pixel agreement before sending a click.
- [x] Keep typing bound to the selected monitor and focused-window context while
  explicitly allowing unverified focused-control context.
- [x] Capture a stable post-input observation without ever retrying input after a
  capture or verification failure.
- [x] Reject compositor restarts, focus changes, workspace switches, output
  changes, and monitor geometry changes before input.
- [x] Keep grid rendering presentation-only; clean pixels determine screenshot
  identity, tile fingerprints, and freshness.
- [x] Classify post-input visual evidence as unchanged, near-target, elsewhere,
  major scene change, or unlocalized change.

## 4. Input delivery and recovery

- [x] Click by converting the normalized screenshot point to Hyprland global
  coordinates, positioning and verifying the cursor, then issuing one
  `ydotool` click.
- [x] Type the requested text with one bounded `ydotool` invocation.
- [x] Complete request, pair, context, freshness, and dependency validation before
  the input boundary.
- [x] Persist the reservation before attempting delivery.
- [x] Classify a proven spawn failure as `not_delivered`.
- [x] Classify timeouts, post-spawn failures, and failed post-input capture as
  ambiguous without exposing subprocess output or typed text.
- [x] Return `OBSERVE_RECOVERY` after delivery failures and prohibit automatic
  input retry.
- [x] Preserve no-input guarantees for malformed requests, stale pairs, changed
  context, changed target pixels, failed reservation, and pre-input cancellation.
- [x] Use single-use authorization and the call ledger rather than a heuristic
  repeated-action circuit breaker.

## 5. Structured diagnostics and privacy

- [x] Keep opt-in tracing on `computer_observe` and `computer`.
- [x] Record bounded stage timing, total timing, subprocess categories,
  `operation_id`, host `call_id`, terminal reason, hashed instance/context
  identity, capture dimensions/bytes/hashes, visual evidence and bounds, and
  requested versus actual click position.
- [x] Return privacy-safe trace data for runtime rejections after trace
  initialization.
- [x] Exclude raw titles, typed text, command arguments, subprocess output, and
  screenshot pixels from default traces and failure messages.
- [x] Redact bounded error detail to categories and byte counts.
- [x] Reject DPMS-off observation before capture with a stable reason code and no
  display-power mutation.
- [x] Keep diagnostics within the two-tool workflow.
- [ ] Initialize tracing early enough to cover malformed requests that currently
  reject before operation setup.
- [ ] Add an explicit local trace bundle only if it can guarantee private
  permissions, bounded size, expiry, and sanitized metadata.

## 6. Performance and native helpers

- [x] Cache a confirmed Hyprland instance signature and rediscover after IPC
  failure or an explicit instance change.
- [x] Use native monotonic timing and bounded fallback timing where available.
- [x] Resize model-facing PNGs in process with a bounded ImageMagick fallback.
- [x] Use native tile fingerprints and in-memory PNG differences.
- [x] Reuse identical screenshot identity while rotating authorization.
- [x] Bound the cached observation fast path to four subprocesses.
- [x] Bound a stable click to ten subprocesses, or nine when the inherited
  instance signature matches the cache.
- [x] Avoid external delay and ImageMagick processes on the native fast path.
- [ ] Establish P50/P95 latency and byte budgets for observation, click, and type.
- [ ] Add binary image handles across Bone to reduce repeated PNG copies and
  base64 encoding.
- [ ] Move capture, diffing, coordinate conversion, stable observation, and input
  authorization into a native backend only if measurements justify it.

## 7. Tests, packaging, and release gates

- [x] Assert the public action enum contains only click and type.
- [x] Assert `computer` requires all three authorization fields and exposes the
  exact ten-property schema.
- [x] Cover field validation and explicit rejection of unsupported action names.
- [x] Cover single-use tokens, stale screenshots, changed context, expired
  screenshots, and operation-generation replay binding.
- [x] Cover reservation, replay, cancellation, response persistence, and
  at-most-once delivery boundaries.
- [x] Cover target-tile races, transformed normalized coordinates, cursor
  verification, and stable pre/post captures.
- [x] Cover click and type spawn failures, timeouts, ambiguous delivery,
  redaction, and observation recovery.
- [x] Cover invalid and boundary PNGs, zero monitor geometry, DPMS-off outputs,
  Hyprland query races, and fallback helpers.
- [x] Cover grid rendering as presentation-only observation behavior.
- [x] Remove obsolete helper packaging and helper-specific tests.
- [x] Update `README.md` and this plan to the strict two-action workflow.
- [x] Run `lua5.4 tests/computer_test.lua` after final documentation and catalog
  generation.
- [x] Regenerate `catalog.json` and verify its computer metadata and source hash.
- [x] Search source, tests, docs, and generated metadata for stale workflow
  references.
- [x] Review the complete diff and working-tree status without discarding
  unrelated changes.
- [ ] Perform a live Hyprland observation, normalized click, and focused-window
  type check.

Release criteria:

- [x] Input is emitted at most once for every tested replay and failure path.
- [x] No input crosses any of 1,000 injected target-tile races.
- [x] Coordinate conversion remains within one logical pixel across the 2,160
  transform, scale, origin, and edge cases.
- [x] Failure responses and traces do not expose typed text, subprocess output,
  window titles, or screenshot bytes.
- [x] Every successful call returns replacement authorization, including
  identical screenshots.
- [x] Every ambiguous delivery requires `computer_observe` recovery.
- [ ] Manual live-desktop behavior matches the generated tool schema.
