# Bone catalog

## Hyprland computer tool

`computer` is a stateless, observe-only tool. It never clicks, types, scrolls, focuses windows, or persists images. Screenshots are captured in memory and returned as ephemeral attachments; the tool never creates screenshot files.

### Parameters

| Field      | Type    | Required | Description                                                                                      |
|------------|---------|----------|--------------------------------------------------------------------------------------------------|
| `action`   | string  | yes      | Must be `"observe"`. This is the only supported action.                                          |
| `monitor`  | string  | no       | Hyprland output name, `"focused"`, or `"other"` (exactly two monitors). Omit with multiple monitors for a discovery contact sheet. |
| `grid`     | boolean | no       | Presentation-only ruler overlay (0–1000 labels, subtle quarter guides).                          |
| `trace`    | boolean | no       | Bounded in-memory stage/process timing trace.                                                    |

No other fields are accepted.

### Single-monitor vs multi-monitor

- **One monitor:** omitted `monitor` observes the sole output directly.
- **Multiple monitors:** omitted `monitor` returns a **non-actionable** contact sheet. The sheet lists every output sorted by name, shows awake captures with a caption (`name | focused: yes/no | workspace: N | power: on/asleep`), and shows sleeping outputs as "DISPLAY ASLEEP / NO SCREENSHOT" placeholders. You must call `computer` again with a concrete `monitor` value to get an actionable observation.

### Actionable observation response

A concrete monitor observe returns metadata and one attached PNG:

- **Monitor metadata:** `name`, `focused`, `workspace`, `power` (on/asleep), `scale`, `transform`, `mode_size`, `logical_size`, `full_resolution_screenshot_size`, `global_logical_origin` (`x`, `y`), and `global_logical_bounds`.
- **Shell coordinate mapping:** normalized `(nx, ny)` in `[0, 1]` maps to Hyprland logical coordinates via:
  ```
  X = origin_x + round(nx * (logical_width - 1))
  Y = origin_y + round(ny * (logical_height - 1))
  ```
- **Grid rulers:** when `grid=true`, ruler labels are presentation-only. Convert with `normalized = ruler_value / 1000`.

### Interaction workflow

Center your workflow on this loop:

1. **Observe** — call `computer(action="observe", monitor="...")` (or `grid=true` for ruler aids).
2. **One shell action** — make exactly one approval-gated `shell` call for one atomic visual action (e.g. `hyprctl dispatch ...`, `ydotool ...`, `wtype ...`).
3. **Brief wait** — allow the action to settle.
4. **Observe again** — call `computer(action="observe", monitor="...")` for the same concrete output and treat that screenshot as confirmation.

Never chain multiple visual actions between observations. Never reuse coordinates from a previous screenshot.

### Preferred tools

- **Compositor/window operations:** `hyprctl` (workspaces, dispatch, clients, etc.)
- **Pointer/click/scroll:** `ydotool`
- **Keys/text:** `wtype`

### Requirements and setup

Run Bone as the desktop user in the Hyprland session. The process needs access to the Hyprland IPC socket. A valid `HYPRLAND_INSTANCE_SIGNATURE` is preferred; the tool can discover the current user's instance when the variable is absent, but rejects ambiguous multiple instances.

The tool itself requires:

- Hyprland tools, including `hyprctl`
- `grim`
- ImageMagick with the `magick` command when native PNG resize is unavailable, and for grids or contact sheets

Approval-gated interaction commands additionally use `ydotool` with `ydotoold` already running and authorized, and `wtype`. If `ydotoold` uses a non-default socket, export `YDOTOOL_SOCKET` in Bone's environment.

Safe checks from the same environment that runs Bone:

```sh
hyprctl instances -j
hyprctl monitors -j
grim - >/dev/null
magick -version
```

These checks do not create screenshot files. Missing sockets, permissions, or session access must be fixed outside the computer tool.

`computer(action="observe")` checks the selected output's Hyprland DPMS state before capturing. A sleeping output fails immediately with `output_dpms_off` and an instruction to wake the display. It never changes display power itself.

### Tracing

Set `trace=true` to include a bounded in-memory diagnostic with stage timings, subprocess counts, dependency exit categories, and capture metadata. Traces exclude command arguments, subprocess output, window titles, and screenshot pixels.

For a minimal bug report:

1. Call `computer(action="observe", monitor="...", trace=true)`.
2. Reproduce the problem with another concrete observe and `trace=true`.
3. Record the `reason_code`, stage timings, and subprocess categories.

Common terminal categories: `completed`, `output_dpms_off`, `hyprland_unavailable`, `hyprctl_unavailable`, `screenshot_unavailable`, `imagemagick_unavailable`, `geometry_mismatch`, `context_changed`, `cancelled`.

### Manual workflow example

1. Call `computer(action="observe", monitor="DP-1")` and confirm the attached screenshot.
2. Use one `shell` call to run `hyprctl dispatch focusmonitor DP-1` (or `wtype` to type text, etc.).
3. Wait briefly.
4. Call `computer(action="observe", monitor="DP-1")` again to confirm the result.
5. If a response reports a failure, do not repeat the shell action or reuse coordinates; recover with a fresh concrete `computer(action="observe", monitor="DP-1")`.
