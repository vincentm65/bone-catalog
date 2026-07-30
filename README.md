# Bone catalog

## Hyprland computer tool

The catalog exposes one stateful `computer` tool with three actions:

- `computer(action="observe")` captures or recovers an observation. Optional
  fields are `monitor`, `grid`, and `trace`.
- `computer(action="click", x=..., y=...)` clicks normalized coordinates on the
  latest screenshot. Optional fields are `target_label`, `settle_ms`, `grid`,
  and `trace`.
- `computer(action="type", text=...)` types into the focused window. Optional
  fields are `settle_ms`, `grid`, and `trace`.

`action` is the only field required for every request. Click and type implicitly
use the latest screenshot returned by the preceding successful `computer` call;
there are no model-facing screenshot identifiers, authorization tokens, or
continuation objects. Action-specific fields are rejected on other actions.

Every successful call captures clean PNG pixels and attaches one fresh ephemeral
PNG, even when the pixels are unchanged. Coordinates are finite normalized
values from `0` through `1` relative to the full selected-monitor screenshot.
They are not percentages or `0`–`1000` values. Select coordinates from the
latest returned PNG, including any monitor transform or scale represented by
that image. With `grid=true`, the displayed `0`–`1000` ruler values are only
presentation labels: convert each one with
`normalized = ruler_value / 1000` before passing `x` or `y`.

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

ImageMagick renders optional ruler overlays and provides bounded compatibility
fallbacks when native Bone PNG helpers are unavailable. A current Bone build
provides native monotonic timers, secure randomness, PNG resizing, tile hashing,
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

`computer(action="observe")` checks the selected output's Hyprland DPMS state
before starting `grim`. A sleeping output fails immediately with
`output_dpms_off` and an instruction to wake the display, rather than consuming
the screenshot timeout. It never changes display power itself.

### Authorization and recovery

The tool preserves internal capture identity, observation and operation
generations, single-use authorization, and a bounded replay ledger. These values
are never exposed as request parameters or response continuation data.

A successfully captured and persisted observation becomes the implicit basis
for the next click or type. Before delivering input, the tool consumes and
persists its internal authorization. A successful input then captures and
persists the replacement observation that authorizes the next action.

Bone supplies a bounded host call ID for each input call; it is not a
`computer` parameter. Replaying the same call ID with identical public
parameters returns its recorded outcome without sending input again. Replaying
an in-flight or ambiguous call also sends no input, and reusing a call ID with
different parameters is rejected. Input is sent at most once and is never
automatically retried.

The complete response and persisted state are committed as one operation. A
replacement observation that was not successfully persisted and returned never
becomes current. Input failures after reservation are recorded before a
recovery response is returned.

Structured failure results distinguish three delivery states:

- `input_delivery="not_sent"` means request, context, or freshness validation
  rejected the action before an input program was attempted.
- `input_delivery="not_delivered"` means reservation occurred, but the input
  executable was proven not to have started.
- `input_delivery="sent_unverified"` means delivery or post-action observation
  is ambiguous. The effect may already have happened.

All three use `retry_input=false`. After any failed, cancelled, or ambiguous
input, do not repeat the action. Call `computer(action="observe")`, review the
attached screenshot, and make a new decision. Missing, expired, consumed,
corrupt, or obsolete internal state also requires a fresh observation.

### Reliability checks

An accepted observation is a transaction: the tool reads output, workspace,
focused-window, geometry, scale, transform, and Hyprland-instance metadata,
captures pixels, then verifies the same metadata again. Pre-input and
post-input screenshots use the same stable-observation path.

Immediately before a click, the tool compares the target tile with the latest
observation. Unrelated changes elsewhere on the monitor do not invalidate that
local check. The normalized point is converted to Hyprland coordinates, the
cursor position is set and read back, and the click is sent only when the
reported position is within one logical pixel.

Typing sends the requested text to the currently focused window. It retains the
same monitor, focused-window, workspace, screenshot-freshness, single-use
authorization, reservation, and at-most-once checks as clicking, but it does not
verify the focused control. Establish and confirm focus from the latest PNG
before typing sensitive text.

Every accepted input is followed by another stable capture. The response
reports whether pixels were unchanged, changed near the click, changed
elsewhere, changed substantially, or changed without localized bounds. This is
visual evidence, not proof that the intended UI effect occurred.

With `grid=true`, the attached image has short top and left edge ticks every 50
ruler units, labels from `0` through `1000` at 250-unit intervals, and subtle
quarter guides. It changes only the attached presentation image. Internal
capture identity, tile fingerprints, freshness checks, and change
classification remain based on the clean capture.

Persisted tool state contains salted context digests and image fingerprints,
not window titles, window classes, typed text, screenshots, or presentation
images.

### Tracing and performance

Set `trace=true` on any action to include a bounded in-memory diagnostic with
stage timings, subprocess counts, dependency exit categories, the operation ID,
the host call ID, a terminal reason code, hashed instance/context identity,
capture dimensions, byte counts and hashes, visual-change evidence and bounds,
and requested versus actual click position. Runtime rejections after trace
initialization return the trace with a stable terminal category.

Default traces exclude command arguments, subprocess output, window titles,
typed text, and screenshot pixels. A persistent local trace bundle is not
exposed.

For a minimal bug report:

1. Start with `computer(action="observe", trace=true)`.
2. Reproduce the problem once with the next implicit action and `trace=true`.
3. Record the operation ID, host call ID, `reason_code`, delivery state, stage
   timings, and subprocess categories. Do not add titles, typed text, or
   screenshot content.
4. If delivery is ambiguous, do not retry; recover with
   `computer(action="observe")`.

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
2. Call `computer(action="observe")` and confirm that the intended monitor PNG
   is attached.
3. Call `computer(action="click", x=..., y=...,
   target_label="Address bar")` using coordinates from that screenshot.
4. Review the attached post-click screenshot and call
   `computer(action="type", text="https://example.com")` after confirming the
   address bar is focused.
5. Review the post-type screenshot and click the visible navigation control if
   needed.
6. If the page is still changing, observe again before choosing another action.
7. If a response reports failed or uncertain delivery, do not repeat it;
   recover with `computer(action="observe")`.
8. Optionally use `computer(action="observe", grid=true)`. Read the displayed
   ruler values as visual aids, then divide each by `1000` before passing it to
   the normalized `x` or `y` click field. The overlay is presentation-only;
   captured state and freshness hashes remain based on the clean screenshot.

If `ydotoold` is unavailable, observation still works, but click and type are
blocked. The failed input call reports the dependency without retrying or
attempting to start or reconfigure the daemon.
