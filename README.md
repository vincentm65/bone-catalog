# Bone catalog

## Hyprland computer tool

The catalog exposes two state-sharing tools:

- `computer_observe` only captures an observation. Optional fields are `monitor`,
  `grid`, and `trace`.
- `computer` performs exactly `action="click"` or `action="type"`. Every call
  requires `action`, `screenshot_id`, and `action_token` from the immediately
  preceding successful tool response.

Every successful call captures clean PNG pixels and returns a replacement
`screenshot_id`/`action_token` pair. `computer_observe` always attaches its PNG;
a continuation can reuse the preceding image when the pixels are unchanged.
`settle_ms`, `grid`, and `trace` are optional continuation fields. A click
requires normalized `x` and `y` coordinates; a non-sensitive `target_label`
remains optional. Typing requires `text` in addition to the common continuation
fields. Action-specific fields are rejected on the other action.

Coordinates are finite normalized values from `0` through `1` relative to the
full selected-monitor screenshot. They are not percentages or `0`–`1000`
values. Select coordinates from the latest returned PNG, including any monitor
transform or scale already represented by that image.

The tool does not launch applications, install packages, start daemons, or
alter device permissions. Use Bone's `shell` tool for application launch and
system inspection.

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

ImageMagick renders optional grids and provides bounded compatibility fallbacks
when native Bone PNG helpers are unavailable. A current Bone build provides
native monotonic timers, random token generation, PNG resizing, tile hashing,
and in-memory PNG differences.

If `ydotoold` uses a non-default socket, export `YDOTOOL_SOCKET` in Bone's
environment.

Safe checks from the same environment that runs Bone include:

```sh
hyprctl instances -j
hyprctl monitors -j
grim /tmp/bone-grim-check.png
magick identify /tmp/bone-grim-check.png
```

Remove the temporary screenshot after checking it. Missing sockets,
permissions, or session access must be fixed outside the computer tool.

`computer_observe` checks the selected output's Hyprland DPMS state before
starting `grim`. A sleeping output fails immediately with
`output_dpms_off` and an instruction to wake the display, rather than consuming
the screenshot timeout. It never changes display power itself.

### Authorization and recovery

Every successfully captured and persisted observation returns a pair:

- `screenshot_id` identifies the clean captured pixels. It can remain unchanged
  when a later capture has identical pixels.
- `action_token` authorizes exactly one continuation. A fresh token is issued
  after every successful call, even when `screenshot_id` is reused.

Always copy both values from the immediately preceding successful response.
Bone supplies a bounded host `call_id` for each input call; it is not a
`computer` parameter.

Before input, the tool consumes the token and persists a bounded `call_id`
outcome ledger. Replaying the same completed call returns its recorded outcome
without sending input again. Replaying an in-flight or ambiguous call also
sends no input, and reusing a `call_id` with different parameters is rejected.
An old completed replay returns a continuation token only while its exact
resulting operation generation is still current. Input is sent at most once and
is never automatically retried.

The complete response and its persisted state are committed as one operation.
A pair that was not successfully persisted and returned is never exposed as a
valid continuation. Input failures after reservation are recorded before a
recovery response is returned.

Structured failure results distinguish three delivery states:

- `input_delivery="not_sent"` means request, context, or freshness validation
  rejected the action before an input program was attempted.
- `input_delivery="not_delivered"` means reservation occurred, but the input
  executable was proven not to have started.
- `input_delivery="sent_unverified"` means delivery or post-action observation
  is ambiguous. The effect may already have happened.

All three use `retry_input=false`. Do not repeat a failed or cancelled action or
reuse its pair. Call `computer_observe`, review the current UI, and make a new
decision from the replacement pair. Old or corrupt state versions also require
a fresh observation.

### Reliability checks

An accepted observation is a transaction: the tool reads output, workspace,
focused-window, geometry, scale, transform, and Hyprland-instance metadata,
captures pixels, then verifies the same metadata again. Pre-input and
post-input screenshots use the same stable-observation path.

Immediately before a click, the tool compares the target tile with the
referenced observation. Unrelated changes elsewhere on the monitor do not
invalidate that local check. The normalized point is converted to Hyprland
coordinates, the cursor position is set and read back, and the click is sent
only when the reported position is within one logical pixel.

Typing sends the requested text to the currently focused window. It retains the
same monitor, focused-window, workspace, screenshot-freshness, single-use
authorization, reservation, and at-most-once checks as clicking, but it does not
verify the focused control. Establish and confirm focus from the latest PNG
before typing sensitive text.

Every accepted input is followed by another stable capture. The response
reports whether pixels were unchanged, changed near the click, changed
elsewhere, changed substantially, or changed without localized bounds. This is
visual evidence, not proof that the intended UI effect occurred.

A grid changes only the attached presentation image. Screenshot identity,
tile fingerprints, freshness checks, and change classification remain based on
the clean capture.

Persisted tool state contains salted context digests and image fingerprints,
not window titles, window classes, typed text, screenshots, or presentation
images.

### Tracing and performance

Set `trace=true` on either tool to include a bounded in-memory diagnostic with
stage timings, subprocess counts, dependency exit categories, `operation_id`,
the host `call_id`, a terminal reason code, hashed instance/context identity,
capture dimensions, byte counts and hashes, visual-change evidence and bounds,
and requested versus actual click position. Runtime rejections after trace
initialization return the trace with a stable terminal category.

Default traces exclude command arguments, subprocess output, window titles,
typed text, and screenshot pixels. A persistent local trace bundle is not
exposed.

For a minimal bug report:

1. Start with `computer_observe(trace=true)`.
2. Reproduce the problem once with the latest pair and `trace=true`.
3. Record the `operation_id`, `call_id`, `reason_code`, delivery state, stage
   timings, and subprocess categories. Do not add titles, typed text, or
   screenshot content.
4. If delivery is ambiguous, do not retry; recover with `computer_observe`.

Common terminal categories include `completed`, `input_delivery_ambiguous`,
`pointer_position_mismatch`, `post_action_observation_failed`, and
`response_persistence_failed`. Ledger replays set `replayed=true`, include a
`ledger_status`, and never repeat input. Validation failures occur before input
and include a recovery message.

The low-risk speed path caches a confirmed Hyprland instance signature and uses
native in-memory PNG resize, tile, and difference helpers when available. Each
image helper has a bounded ImageMagick fallback. Regression tests bound the
native fast path to at most four subprocesses for a cached observation and ten
for a stable click, or nine when the inherited Hyprland signature matches the
cache. These paths use no external delay or ImageMagick process.

### Manual Firefox workflow

This is a manual end-to-end check. Select every coordinate from the latest
returned screenshot.

1. Launch Firefox with Bone's `shell` tool and focus its window.
2. Call `computer_observe`. Confirm that the intended monitor PNG is attached,
   then save both `screenshot_id` and `action_token`.
3. Call `computer(action="click", x=..., y=..., target_label="Address bar",
   screenshot_id=..., action_token=...)`.
4. Copy the replacement pair from the click response and call `type` with the
   URL. Typing uses the current focused window, so confirm the address bar focus
   before sending text.
5. Review the post-input screenshot, copy its replacement pair, and click the
   visible navigation control.
6. If the page is still changing, call `computer_observe` for a fresh capture
   before choosing another action. Never infer token freshness from an
   unchanged `screenshot_id`.
7. Reuse an older token once and confirm it is rejected before input. If a
   response reports uncertain delivery, do not repeat it; recover with
   `computer_observe`.
8. Optionally use `computer_observe(grid=true)`. The overlay is
   presentation-only; captured state and freshness hashes remain based on the
   clean screenshot.

If `ydotoold` is unavailable, observation still works, but click and type are
blocked. The failed input call reports the dependency without retrying or
attempting to start or reconfigure the daemon.
