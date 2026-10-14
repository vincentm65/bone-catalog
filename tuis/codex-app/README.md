# Codex App

The standard UI dressed like the Codex desktop app: its dark palette for
surfaces, text and diffs, bone's own `black` palette for links, code and
the accent. Every key, the tray, tool summaries, menus and the statusline
are the standard UI's.

* The sidebar is the standard conversation sidebar drawn like Codex's,
  open from the start: New thread, Search (type while it has the
  keyboard), Diff, Processes (tab) and Plugins, then threads in
  collapsible categories: Running, Pinned, Today, Yesterday, Previous 7
  days, Older and Archived, or by project folder (the "by date ⇄" button
  or alt+g). alt+p pins a thread. Each thread shows a spinner while it
  works, a dot when it finished out of sight, and its age. ctrl+b (or «)
  folds it into an icon rail and back; ctrl+o moves into it, esc leaves.
* A top bar: sidebar toggle, the thread title, a `+2 -1` pill that opens
  `/diff`, the branch and the terminal toggle (ctrl+]).
* A narrow centered thread; your messages in right-aligned bubbles with
  "Worked for 1m 12s" and a hairline under each.
* The composer as a filled card: the working tree's changes with
  Review (`/diff`), the text, then + (paste an attachment), Full access,
  the model (opens the providers page), the reasoning effort (click to
  cycle) and send / stop. Folder and branch sit under it.
* "What will you build?" on an empty thread.

ctrl+d opens `/diff` when the git-diff plugin is installed and quits on an
empty prompt otherwise.

Install from `/catalog`, then switch with `/tui use codex-app`.
