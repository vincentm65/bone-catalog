# Bone catalog

## Hyprland computer tool

The catalog exposes two state-sharing tools:

- `computer_observe` is read-only. It captures a stable Hyprland monitor
  observation and returns a `screenshot_id` plus a single-use `action_token`.
- `computer` inspects that observation, discovers semantic controls, waits for
  UI changes, or sends input. Input actions require both values from the most
  recent successfully persisted observation.

Screenshots are PNG images. Coordinates are finite normalized values from `0`
through `1` relative to the full selected monitor; they are not percentages or
`0`–`1000` values. The tool does not launch applications, install packages,
start daemons, or alter device permissions. Use Bone's `shell` tool for
application launch and system inspection.

### Requirements and setup

Run Bone as the desktop user in the Hyprland session to be controlled. The
process needs access to the Hyprland IPC socket. A valid
`HYPRLAND_INSTANCE_SIGNATURE` is preferred; the tool can discover the current
user's instance when the variable is absent, but it rejects ambiguous multiple
instances instead of guessing.

Install these dependencies through the operating system:

- Hyprland tools, including `hyprctl`
- `grim`
- ImageMagick with the `magick` command
- `ydotool`, with `ydotoold` already running and authorized
- Python 3, PyGObject/GI, and AT-SPI bindings for semantic targeting and safe
  typing-focus verification

ImageMagick remains required for magnified target inspection and optional
grids. On older Bone builds it is also the compatibility path for overview
resizing, tile/region hashing, and image differences. A current Bone build
provides native monotonic timers, cancellable waits, random token generation,
PNG resizing, tile hashing, exact region hashing, and in-memory PNG
differences. The catalog feature-detects each helper independently and keeps
bounded ImageMagick or timer fallbacks where available.

If `ydotoold` uses a non-default socket, export `YDOTOOL_SOCKET` in Bone's
environment.

Safe checks from the same environment that runs Bone include:

```sh
hyprctl instances -j
hyprctl monitors -j
grim /tmp/bone-grim-check.png
magick identify /tmp/bone-grim-check.png
python3 -c 'import gi; gi.require_version("Atspi", "2.0"); from gi.repository import Atspi'
```

Remove the temporary screenshot after checking it. Missing sockets,
permissions, session-bus access, or AT-SPI exposure must be fixed outside the
computer tool.

`computer_observe` checks the selected output's Hyprland DPMS state before
starting `grim`. A sleeping output fails immediately with
`output_dpms_off` and an instruction to wake the display, rather than consuming
the screenshot timeout. It never changes display power itself.

### Authorization and recovery

Every successfully captured and persisted observation returns a pair:

- `screenshot_id` identifies the clean captured pixels. It can remain unchanged
  when a later capture has identical pixels.
- `action_token` authorizes exactly one input action. A fresh token is issued
  after every newly persisted observation, even when `screenshot_id` is reused.

Always copy both values from the immediately preceding observation response.
`inspect`, `semantic_find`, and `wait` do not send input, but their successful
responses still rotate the token, so older tokens must not be reused. Bone
supplies a bounded host `call_id` for each mutating tool call; it is not a
`computer` parameter.

Before input, the tool consumes the token and persists a bounded `call_id`
outcome ledger. Replaying the same completed call returns its recorded outcome
without sending input again. Replaying an in-flight or ambiguous call also
sends no input, and reusing a `call_id` with different parameters is rejected.
Input is never automatically retried.

Structured failure results distinguish three delivery states:

- `input_delivery="not_sent"` means request, context, or freshness validation
  rejected the action before an input program was attempted.
- `input_delivery="not_delivered"` means reservation occurred, but the input
  executable was proven not to have started. Fix the dependency, call
  `computer_observe`, and decide whether to create a new action from that fresh
  screen. Replaying the old `call_id` only returns its ledger outcome.
- `input_delivery="sent_unverified"` means delivery or post-action observation
  is ambiguous. The effect may already have happened. Do not repeat the action;
  call `computer_observe` and inspect the current UI before making any new
  decision.

When these fields are returned, all three use `retry_input=false` and direct
recovery through `computer_observe`; only the ambiguous case blocks
authorization because input may have crossed the boundary. A fresh observation
rotates authorization in every case. Old or corrupt state versions likewise
require a fresh observation.

### Reliability checks

An accepted observation is a transaction: the tool reads output, workspace,
focused-window, geometry, scale, transform, and Hyprland-instance metadata,
captures pixels, then verifies the same metadata again. Pre-input and
post-input screenshots use the same stable-observation path.

Immediately before coordinate input, the tool compares the intended target
tile (both endpoint tiles for a drag) with the referenced observation. Changes
elsewhere on the monitor do not invalidate that local check. `click_locked`
adds a short-lived exact patch lock created by `inspect`. Coordinate pointer
moves are read back through Hyprland and must be within one logical pixel before
a click, drag, or scroll proceeds.

Semantic targeting uses AT-SPI controls scoped to the focused window:

1. Call `computer` with `action="semantic_find"` and the current
   `screenshot_id`. Optional bounded filters are `query`, `roles`, `near`, and
   `max_results`.
2. Select an exact returned `semantic_id`. Results are ranked toward named,
   enabled, visible, actionable controls and report traversal, truncation, and
   privacy-safe rejection counts.
3. Call `semantic_click` with that ID plus the latest `screenshot_id` and
   `action_token`. The helper re-resolves an opaque semantic fingerprint just
   before delivery. It invokes a verified AT-SPI action directly when one is
   available, otherwise it uses the freshly resolved center as the explicit
   coordinate fallback.

Ambiguous fingerprints or changed controls are rejected without input.
Password controls are returned as `[protected]`, and their names and values are
not read. Before `type`, the helper requires exactly one focused, safely
editable AT-SPI control; typing is rejected when that cannot be verified.

Persisted tool state contains salted context and semantic-name digests rather
than window titles, window classes, typed text, accessibility names, or
screenshots. Human-readable semantic names can still appear in the immediate
`semantic_find` response so a caller can choose a target; protected names
remain redacted.

### Tracing and performance

Set `trace=true` on either computer tool to include a bounded, in-memory
diagnostic with
stage timings, subprocess counts, dependency exit categories, the
`operation_id`, the host `call_id`, a terminal reason code, hashed
instance/context identity, capture dimensions/byte counts/hashes, visual-change
evidence and bounds, requested versus actual pointer position, and bounded
semantic traversal/match/truncation/rejection counters. Runtime rejections after
trace initialization return the trace with a stable terminal category. Default
traces exclude command arguments, subprocess output, titles, typed text,
accessibility names and values, and screenshot pixels. A persistent local trace
bundle remains planned and is not yet exposed.

For a minimal bug report:

1. Start with `computer_observe(trace=true)`.
2. Reproduce the problem once with the latest IDs and `trace=true`.
3. Record the `operation_id`, `call_id`, `reason_code`, delivery state, stage
   timings, and subprocess categories. Do not add titles, typed text, or
   screenshot content.
4. If the response says delivery is ambiguous, do not retry; recover with
   `computer_observe`.

Common terminal categories include `completed`, `input_delivery_ambiguous`,
`pointer_position_mismatch`,
`post_action_observation_failed`, and `response_persistence_failed`. Semantic
failures use stable helper categories such as `target_stale`,
`target_ambiguous`, `activation_rejected`, and
`focused_control_not_editable`. Ledger replays set `replayed=true`, include a
`ledger_status`, and never repeat input. Validation failures occur before input
and include an actionable recovery message.

The low-risk speed path caches a confirmed Hyprland instance signature, uses
native cancellable waits when the Bone runtime provides them, and uses native
in-memory PNG resize, tile, exact-region, and difference helpers instead of
ImageMagick subprocesses. Native resize removes the large-overview resize
process; native region hashing removes the former `click_locked` crop/hash
process. Each has an older-Bone ImageMagick fallback.

Regression tests currently bound the native fast path to at most four
subprocesses for a cached observation and ten for a stable coordinate click
(two transactional captures plus verified input and, when needed, one
defensive instance rediscovery). A click is nine when the cached signature
matches the inherited Hyprland signature. These paths use no external `sleep`
or ImageMagick process. Identical captures reuse the prior screenshot
attachment while still rotating authorization. Per-call Python/GI startup,
direct model-sized capture, binary blob handles, a persistent semantic bridge,
and a fully native backend remain future work.

### Manual Firefox workflow

This is a manual end-to-end check. Coordinates below are selected from each
returned screenshot.

1. Launch Firefox with Bone's `shell` tool and focus its window.
2. Call `computer_observe`. Confirm that a PNG of the intended monitor is
   attached, then save both `screenshot_id` and `action_token`.
3. Call `computer(action="click", x=..., y=..., screenshot_id=...,
   action_token=...)` on Firefox's address bar.
4. Copy the fresh pair from the click response and call `type` with the URL.
   The tool proceeds only if AT-SPI verifies that exactly one safely editable
   control has focus.
5. Copy the next fresh pair and call `key` with `keys="ENTER"`.
6. Use `wait` if the page needs time to render. Copy the fresh pair from every
   successful response; do not assume an unchanged `screenshot_id` means the
   token is unchanged.
7. Call `scroll` with normalized coordinates over a visible scrollable region
   and a nonzero `amount`, then inspect the post-action PNG.
8. Reuse an older token and confirm it is rejected before input. If a response
   reports uncertain delivery, do not repeat it; recover with
   `computer_observe`. The automated idempotency harness, rather than a live
   manual retry, verifies that replaying the same host `call_id` emits no input.
9. Optionally use `computer_observe(grid=true)`. The overlay is
   presentation-only; the captured state and freshness hashes remain based on
   the clean screenshot.

If `ydotoold` is unavailable, observation and semantic discovery can still be
tested, but coordinate input is blocked. The failed input call reports that
dependency without retrying or attempting to start/reconfigure the daemon.
