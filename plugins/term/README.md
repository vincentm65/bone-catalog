# Terminal

Interactive local shells and commands in pseudo-terminal panels (Unix). Nothing
is sent to a model. Requires Bone **3.0.3** or newer; install this directory as
`~/.bone/plugins/term` and load it with `/plugins load term`.

The terminal UI uses this plugin's panel renderer. The desktop app already
has the same `/term` command, ctrl+] / ctrl+5 keys and panel terminals, so
this plugin does not replace them there.

## Commands and keys

- `/term` (alias `/terminal`): open `$SHELL`, falling back to `/bin/sh`.
- `/term command`: run a shell command. Its output stays visible after it exits.
- `/term close`: close the focused terminal, or the last terminal if the prompt
  has focus. Closing stops its program; an interactive shell exiting closes its
  panel automatically.
- **ctrl+]** or **ctrl+5**: open/focus the last terminal from the prompt; inside
  the terminal, return to the prompt. ctrl+5 is the legacy-terminal encoding of
  ctrl+]. **esc** is sent to the program (for editors and other interactive apps).
- **wheel**, **pageup / pagedown**, and **home / end**: scroll terminal history.
  Typing or pasting returns to live output. Programs that enable xterm mouse
  reporting receive clicks, drags, and wheel events. Paste honors bracketed paste.

New terminals dock at the bottom, occupying 40% of the available space. Their
working directory defaults to the current chat's directory. After Bone expires
a finished job from its bounded cache, the last visible screen remains; older
scrollback is no longer available.

## Lua API and Windows integration

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
