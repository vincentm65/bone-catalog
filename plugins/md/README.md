# Markdown

A standalone, Lua-only Bone 3 plugin. `/md` opens a large popup over the chat with
searchable Markdown filenames, and reads the one you open. Nothing is sent to a model,
and your chat and draft stay untouched. No custom runtime overrides or Rust
changes are required.

## Install

Install **md** from `/catalog`, then run `/plugins load md` (or restart Bone).
From this repository you can also use:

```sh
python3 install.py md
```

## Use

- `/md`: browse `.md` files recursively under the current session's working
  directory; a new chat uses Bone's launch directory.
- `/md docs/usage.md`: select a relative path after discovery.
- Type to filter relative paths; every search word must match. `backspace`
  edits the filter, and `ctrl+u` clears it. The first 500 matches are listed;
  typing narrows the rest.
- Up/down, page keys and `home`/`end` choose a file; `enter` (or a click on the
  chosen one) reads it.
- In the reader, up/down, page keys and the wheel scroll; `tab`, `b`, left or
  **‹ Files** go back to the list.
- `ctrl+r` rescans and reloads the selected file; `esc` closes the popup.

The same view is drawn by the terminal and the desktop app. The reader reuses
Bone's Markdown renderer, including headings, emphasis, links, lists, quotes,
fenced code and wrapping tables. Links are displayed, not executed.

## Requirements and limits

Uses the existing `bone.job` API and `find` / `head` from your PATH. Discovery and
reads are asynchronous; closing, replacing or unloading the popup cancels jobs.
No provider or API key is needed.

Hidden files and case-insensitive `.md` extensions are included. `.git` internals
and symlinks are excluded during discovery. UTF-8 filenames, including spaces,
quotes and newlines, are supported. Scans stop after 30 seconds or 20,000 files
and report incomplete results. Reads time out after 10 seconds and are capped at
1 MiB; empty, unreadable, oversized and NUL-containing files have explicit
messages. This is a browser for trusted local projects, not a filesystem sandbox
against concurrent symlink replacement.

## Tests

Run from the catalog checkout, with a Bone 3 source checkout alongside it:

```sh
luajit tests/md_test.lua
# Or point to another checkout:
BONE_SOURCE=/path/to/bone3 luajit tests/md_test.lua
# Real popup smoke test in an isolated tmux session, without model calls:
BONE_BIN=/path/to/bone3 python3 tests/md_tmux_test.py
python3 check.py
python3 gen-index.py --check
```

The tests mock asynchronous jobs and Markdown parsing but exercise the real
Bone Lua popup-box helper. They cover filtering, geometry, cache reflow,
scroll-position restoration, job cancellation, stale callbacks, file limits,
errors, command registration and plugin shutdown.
