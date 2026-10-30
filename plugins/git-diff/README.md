# Git Diff

A read-only Git diff viewer in a full-height right sidebar (room for about 110
columns of patch, between a quarter and two fifths of the window, so the chat
stays in sight), in the terminal and the desktop app. Uses Bone's existing
`DiffAdd` / `DiffDelete` background bands across the whole row, wrapped code
beside a fixed line-number gutter, and a file tree whose counts sit on the
right. The prompt and chat stay on the left. Small terminals and other docked
panels may reduce the allocation to preserve the chat minimum.

Install `git-diff` through `/catalog` (or copy this folder into
`~/.bone/plugins/git-diff`). Requires Git and Bone's panel and streaming-job APIs.
No core plugin or new theme is needed. The initial view is a collapsible changed-file
tree with per-file addition/deletion counts; opening a file shows only its patch.

- `/diff` or `ctrl+d`: open/focus the sidebar, or close it if already open.
- `/diff refresh`: open it if closed, otherwise refresh without moving the scroll.
- `r`: refresh.
- `s`: cycle **All tracked → Unstaged → Staged**, or pick one from the tabs
  (left/right on them, or a click).
- `q` or `ctrl+d`: close.
- Up/Down or `k`/`j`: move through the tabs and the tree; past the end, scroll
  a file's patch.
- Enter or Space: open a file or expand/collapse a directory. A click selects
  and opens the same way and gives the sidebar the keyboard.
- Left, `b` or **‹ Files**: return to the file tree.
- Page Up/Down, Home/End, mouse wheel: scroll.
- `Esc`: return focus to the prompt, leaving the sidebar open.

The desktop sidebar shows the same title, counts and patch. Nothing in either
frontend stages or reverts a change.

**All tracked** compares the working tree with HEAD, including staged and
unstaged changes. Before the first commit it compares with an empty tree.
Untracked files are not shown. The file breadcrumb replaces Git's repeated file
headers and index hashes. Hunk headers, rename metadata, binary change notices,
and missing-final-newline markers are retained. Line-number gutters use at least three columns per number, with extra spacing
around the diff marker; narrow panels use a reduced gutter. A blank line separates
deletion/addition blocks and hunk headers.

The viewer uses the current session's working directory, refreshing on open,
completed turns, and session changes (detected within 500 ms). External edits can
be refreshed with `r`; there is no continuous Git polling. Commands run
asynchronously with a ten-second timeout; closing, refreshing, switching sessions,
or unloading prevents stale results from replacing the current view. Output over
the buffered job limit (4 MiB) displays a warning rather than a partial patch.
There are no staging, reverting, or editing operations.
