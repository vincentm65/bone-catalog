# Windows

Tiled panes, like vim or tmux splits. A pane holds a chat or any focusable
node panel, including a terminal. Each chat streams live with its own prompt
and statusline. The active pane has the keyboard; the last chat pane is the
one chat actions change. Other chats show their drafts and are drawn by Rust
from their own render cache, so a background chat costs nothing until its
session changes.

Needs a Bone with `chat:<id>`, `prompt:<id>` and `statusline:<id>` layout
leaves, `bone.chat.open` and `bone.ui.geometry`. The windows themselves
(splits, focus, keys, saving) are `lua/windows/tree.lua`; `tui.lua` and
`gui.lua` draw them.

## Keys

Press the prefix (`alt+w` by default; `/config` → Windows), then:

| Key | Does |
|---|---|
| `t` | open a terminal in a new window, right of this one |
| `v` / `s` | split right / below with a new chat |
| `p` | pick the session the window shows |
| `h` `j` `k` `l` (or arrows) | focus the window in that direction |
| `w` | focus the next window |
| `;` | focus the window you were in before |
| `H` `J` `K` `L` | swap the window with its neighbor in that direction |
| `<` `>` / `-` `+` | narrower / wider, shorter / taller; repeat without the prefix for a second |
| `=` | make every window the same size |
| `z` | zoom: the focused window alone, and back |
| `r` | rotate: every window moves one place along |
| `b` | broadcast: messages you send also go to every other window |
| `q` | close the window (the session stays) |
| `o` | close every other window |

`/win term|vsplit|split|pick|close|only|next|equal|zoom|rotate|broadcast` does the same.
`/win only` closes every other pane but keeps the active terminal or panel.
Closing or leaving the last panel returns to the existing chat without
creating another buffer.

The focused window's title bar is highlighted. A spinner in a title means
that session is running; a `•` means a turn finished there since you last
looked.

## Mouse

- Click a window to focus it; the wheel scrolls the window under it.
- Drag a `│` or `─` line between windows to resize them.
- Drag a window by its title bar onto another. The center swaps them; an
  edge (the outer fifth of the shorter side, the nearer one in a corner)
  splits that window and moves this one there. A blue outline shows which,
  and a side too small to split swaps instead. Nothing happens over the
  window you are dragging. Click the focused window's title to pick what
  it shows.
- `✕` or a middle click on a title closes a window; a double click zooms.

## In the desktop app

The same windows, keys and `/win` commands, drawn beside the sessions
sidebar. Each window has a title bar over its chat; the focused one has the
composer, the others show their unsent text, and a click there (or on a
title) focuses that window. Drag the line between two windows to resize
them; double-click a title to zoom, right-click it to pick what it shows,
and `✕` closes. Drag a title onto another window's center to swap, or onto
an edge to move it into a split. A tinted outline previews the drop;
releasing over the source window, a divider, or outside the chat area
cancels. An edge too small to split swaps instead. Dragging is disabled
while zoomed. Terminal windows use the same keys as the TUI: `alt+w` then
`t` (or your configured prefix), `/win term`, `/term`, and `ctrl+]` / `ctrl+5`.
Needs a Bone whose GUI library has `bone.nodes.window.area` (3.0.3 and later).
Panel panes also need `window.panel`, `window.embed`, and `window.attach_panel`.
The plugin installs that hook, so a terminal and any other focusable node
panel use the same title, resize, drag, zoom, and focus behavior. With an
older or custom library the plugin says so and leaves the window alone.

## Terminals

`/term` (or `/term <command>`) and prefix then `t` open a terminal in a new
window beside the one you are in. `ctrl+]` / `ctrl+5` open one or refocus
the last terminal; press again inside it to return to the chat prompt. It is a window like the others: move to
it, swap, resize, zoom or close it (`q`, `✕`, or `/term close`). The prefix works inside it; every other key
goes to the program, and `ctrl+]` goes back to the prompt. When the program
ends the window closes, and closing the window stops the program. Terminals
are not saved with the windows. In the TUI this uses the `term` plugin's
`bone.ui.terminal`; the GUI uses the built-in `bone.terminal` module.

## Notes

- Opening a session another way (`ctrl+o`, a sub-agent, `ctrl+n`) changes
  what the focused window shows, or focuses the window that already has it.
- The tree replaces the `chat` leaf of whatever `bone.ui.layout` you have.
  Rows above the chat stay where they were; the rows under it (prompt,
  statusline…) go into every window. Docked panels sit beside the focused
  window; put a panel in the layout (`{ panel = "id" }`) to place it elsewhere.
- A window whose session is deleted closes.
- With *Watch sub-agents* on (`/config` → Windows), each new sub-agent opens
  in a window under its owner's.
- The windows, their sizes and zoom state are saved, and come back at the next
  start. A Lua configuration reload keeps the current layout and reuses the
  existing chat buffers, including blank chats and their unsent drafts. A failed
  reload leaves the old layout alone.
- Buffer numbers are reused only within a Lua reload, never across restarts.
  As before, terminal windows are not restored: Lua reload stops their jobs.
- A session shows in one window at a time.
- Zoom follows whichever pane has the keyboard, including a panel revealed
  from beneath it. A hidden panel is shown before it is focused.

## Tests

```sh
luajit tests/windows_test.lua
BONE_BIN=/path/to/bone python3 tests/windows_tmux_test.py  # requires tmux; isolated config, no model calls
```
