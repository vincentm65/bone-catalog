# Bone catalog

## Hyprland computer tool

The `computer` tool observes and controls the focused monitor in a running Hyprland session. It returns JPEG screenshots and uses normalized `0`–`1000` coordinates. It intentionally does not launch applications or perform system setup; use Bone's existing `shell` tool to launch applications.

### Requirements and setup

Run Bone as the desktop user inside the Hyprland session that will be controlled. The process must inherit a valid `HYPRLAND_INSTANCE_SIGNATURE` and be able to run `hyprctl monitors -j`.

Install these dependencies using your operating system's normal package-management process:

- Hyprland tools, including `hyprctl`
- `grim`
- ImageMagick with the `magick` command
- `ydotool`

`ydotoold` must already be running with permission to create input events. Start and configure it yourself according to your distribution's security model. If it uses a non-default socket, export `YDOTOOL_SOCKET` in Bone's environment. Bone and the catalog tool never install packages, start `ydotoold`, alter device permissions, or attempt privileged setup.

Before use, verify from the same environment that runs Bone:

```sh
hyprctl monitors -j
grim /tmp/bone-grim-check.png
magick identify /tmp/bone-grim-check.png
ydotool mousemove --absolute 0 0
```

Remove the temporary screenshot after checking it. The `ydotool` command should connect to the intended daemon socket; a missing-socket or permission error must be resolved outside Bone.

### Manual Firefox workflow

This workflow is a manual end-to-end check. Coordinate values are examples; choose targets from each returned screenshot.

1. Launch Firefox with Bone's `shell` tool, for example `firefox`, and wait for its window to become focused. Do not add launching behavior to `computer`.
2. Call `computer` with `action="observe"`. Confirm the focused monitor is shown and save the returned `screenshot_id`.
3. Call `computer` with `action="click"`, normalized `x`/`y` coordinates for Firefox's address bar, and that exact `screenshot_id`.
4. Use the new screenshot ID returned by the click for `action="type"` with a URL such as `https://example.com`.
5. Use the new screenshot ID returned by typing for `action="key", keys="ENTER"`.
6. Use each newly returned screenshot ID for the next operation. Call `action="wait", duration_ms=1000` if the page needs time to render, then verify the page in its returned screenshot.
7. Call `action="scroll"` with normalized coordinates over the page and a nonzero `amount`; verify the returned screenshot moved through the page.
8. Retry any action with an older screenshot ID and verify that it is rejected as stale before input is emitted. Changing focused-monitor geometry between observation and action should likewise require a new observation.
9. Optionally call `observe` with `grid=true` and verify the faint 10×10 overlay. A normal `observe` should remain clean.

If `ydotoold` is unavailable, observation can still be checked, but the input portion of this workflow is blocked until the user provides a working daemon and socket. Do not start or reconfigure it automatically.
