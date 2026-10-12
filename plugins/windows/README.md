# windows

Tiled chat windows, like vim or tmux splits: several sessions on screen at
once, each streaming live. The focused window is the chat on screen (the
prompt sends to it); the others are drawn by Rust from their own render
cache, so a background window costs nothing until its session changes.

Needs a Bone with `chat:<id>` layout leaves, `bone.chat.open` and
`bone.ui.geometry` (3.0.2).

## Keys

Press the prefix (`alt+w` by default; `/config` → Windows), then:

| Key | Does |
|---|---|
| `v` / `s` | split right / below, picking a session (or a new chat) |
| `n` | split right with a new chat |
| `h` `j` `k` `l` (or arrows) | focus the window in that direction |
| `w` | focus the next window |
| `H` `J` `K` `L` | swap the window with its neighbor in that direction |
| `<` `>` / `-` `+` | narrower / wider, shorter / taller |
| `=` | make every window the same size |
| `z` | zoom: the focused window alone, and back |
| `q` | close the window (the session stays) |
| `o` | close every other window |

`/win vsplit|split|new|close|only|next|equal|zoom` does the same.

## Mouse

- Click a window to focus it; the wheel scrolls the window under it.
- Drag a `│` separator to resize columns; drag a window's title bar up or
  down to resize rows.
- Drag a window by its `⠿` grip onto another to swap them.
- `✕` closes a window.

## Notes

- Opening a session another way (`ctrl+o`, a sub-agent, `ctrl+n`) changes
  what the focused window shows, or focuses the window that already has it.
- The tree replaces the `chat` leaf of whatever `bone.ui.layout` you have,
  so the prompt, statusline, regions and panels stay where they were. Docked
  panels sit beside the top-left window; put a panel in the layout
  (`{ panel = "id" }`) to place it elsewhere.
- The windows and their sizes are saved, and come back at the next start.
- A session shows in one window at a time.
