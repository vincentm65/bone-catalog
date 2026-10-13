# windows

Tiled chat windows, like vim or tmux splits: several sessions on screen at
once, each streaming live with its own prompt and statusline. The focused
window is the chat on screen (you type in its prompt); the others show
their drafts and are drawn by Rust from their own render cache, so a
background window costs nothing until its session changes.

Needs a Bone with `chat:<id>`, `prompt:<id>` and `statusline:<id>` layout
leaves, `bone.chat.open` and `bone.ui.geometry`.

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

The focused window's title bar is highlighted. A spinner in a title means
that session is running; a `•` means a turn finished there since you last
looked.

## Mouse

- Click a window to focus it; the wheel scrolls the window under it.
- Drag a `│` or `─` line between windows to resize them.
- Drag a window by its title bar onto another to swap them; click the
  focused window's title to pick what it shows.
- `✕` or a middle click on a title closes a window; a double click zooms.

## Terminals

`/term` (or `/term <command>`), `ctrl+]` and `t` open a terminal in a new
window beside the one you are in. It is a window like the others: move to
it, swap, resize, zoom or close it (`q`, `✕`, or `/term close`). The prefix works inside it; every other key
goes to the program, and `ctrl+]` goes back to the prompt. When the program
ends the window closes, and closing the window stops the program. Terminals
are not saved with the windows. Needs a Bone with `bone.ui.terminal`.

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
- The windows and their sizes are saved, and come back at the next start.
- A session shows in one window at a time.
