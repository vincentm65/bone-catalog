# Terminal

Interactive local shells and commands in pseudo-terminal panels (Unix). Nothing
is sent to a model. Requires Bone **3.0.3** or newer; install this directory as
`~/.bone/plugins/term` and load it with `/plugins load term`.

`/term` and **ctrl+]** open one terminal panel with **tabs and split panes**, in
the terminal UI and the desktop app alike (there it takes over bone's own `/term`
and ctrl+], and gives them back when unloaded). Each pane is its own shell.

## Commands and keys

- `/term` (alias `/terminal`): a new tab with `$SHELL` (else `/bin/sh`).
- `/term command`: a new tab running a command. Its output stays after it exits,
  marked with the exit code; **enter** closes it.
- `/term close`: close the panel and every program in it.
- **ctrl+]** or **ctrl+5**: from the prompt, open or focus the terminal; inside
  it, back to the prompt. **esc** goes to the program (editors need it).

While the terminal has the keyboard, with no prefix:

| Key | Does |
| --- | --- |
| alt+t | a new tab, in the focused pane's folder |
| alt+1 … alt+9 · alt+[ alt+] | that tab · the tab before, after |
| alt+\ · alt+/ | split right · split below (alt+- too, in a terminal) |
| alt+arrows | move to the pane in that direction |
| alt+shift+arrows | move the divider |
| alt+z | zoom the pane to the whole tab, and back |
| alt+x | close the pane (alt+w stays the windows plugin's) |
| wheel, shift+pageup/pagedown, ctrl+home/end | scroll back; typing returns to live output |

The mouse: a click focuses a pane, a divider drags, a tab is a click away
(middle click closes it, **+** opens one; × on a tab in the desktop app). A
program that asks for the mouse (vim, htop) gets clicks and the wheel. Paste
goes to the focused pane, bracketed when the program asks.

With the **windows** plugin loaded, the terminal is a window of its own beside
the chats (in both frontends): moved, resized, zoomed and closed like any other,
and `alt+w t` opens it there. Without it, the panel docks at the bottom.

A tab is named after what runs in front of it (`nvim`, `htop`), or the shell's
folder; `·3` says it has three panes and `⤢` that one is zoomed. A new pane or
tab starts in the folder the focused shell is in. The panel docks at the bottom
(40%); every color is a group linked to the scheme's (`TermBorder`,
`TermBorderActive`, `TermTab`, `TermTabActive`, `TermCursor`).

## Lua API and Windows integration

Other plugins still open terminals of their own (one program per panel) through
the module below; in the desktop app that is bone's `require("bone.terminal")`.
The compatibility module remains `require("bone.ui.terminal")`:

```lua
local term = require("bone.ui.terminal")
term.defaults = { dock = "right", size = 0.5 }
term.open({ id = "logs" }, { cmd = "tail -f app.log", cwd = "/tmp" })
term.job("logs"):write("\3") -- send ctrl+c
term.close("logs")
term.close_all()
```

`open(spec, opts)` accepts all panel options (including `on_close`); `opts.cmd`
can be a shell command or argv list. `job(id)` returns the job handle;
`toggle()` shows/focuses the last terminal or opens one. `escape` and
`passthrough` are editable key sets. Duplicate panel ids are rejected without
cancelling the existing terminal.

The **windows** plugin can require this same module and wrap `open` to place
terminals in its layout. Keep term loaded before windows; if windows was loaded
while term was unavailable, reload windows after loading term. No changes to
windows are needed. The public module table and original `open` trampoline
survive term unload/reload, so windows' existing wrapper still works. While
term is unloaded (or required before term loads) it cannot start terminals.
Shutdown also evicts its module-cache entry even if another plugin required it
first, so loading term always activates a fresh generation. Defaults and custom key sets remain
in memory across term reloads; jobs and panels do not.

`/plugins unload term` and `/plugins reload term` close **all** tracked panels
and cancel their jobs, even if opened from another plugin's callback. The paste
handler is registered eagerly under term's ownership and explicitly removed
on shutdown. Closed/replaced terminals and previous module generations ignore
late callbacks. Shutdown is idempotent and continues cleanup if a caller's
close callback fails.

## Tests

From the catalog root:

```sh
luajit tests/term_test.lua
BONE_BIN=/path/to/bone python3 tests/term_tmux_test.py
```

The tmux test uses a temporary config and project, an HTTP model-call trap,
and no installed plugins or user settings.
