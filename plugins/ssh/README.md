# SSH

Open a desktop bone window on another machine's bone, with saved connections.

```
/ssh                    # the SSH window: saved connections, tests, a form
/ssh work box           # connect to a saved one
/ssh new                # the form for a new one
/ssh edit work box      # change a saved one
/ssh devbox             # connect once, nothing saved (user@host[:dir] too)
```

**The SSH window** lists your saved connections (the last used first), each
with its target, when you last used it and how its last test went, and under
them the hosts of `~/.ssh/config` you have not saved yet (enter makes one a
profile). Keys: enter connects, `t` tests, `e` edits, `d` deletes (it asks),
`n` adds one, esc closes.

**The form** has Name and Host (required, marked `*`), User, Port, Key file,
Start directory and More ssh options. Each says what it is for, and mistakes
show as you type: a missing field, a name already used, a port out of range,
a key file that does not exist, a space in a host. Typing `user@host` in Host
fills in User (spaces in a user name are fine). Test connection (ctrl+t)
logs in and says what the machine runs, where bone is and its home directory,
or what went wrong and how to fix it; when the other machine does not accept
this one's key, it shows the public key with a button to copy it. ctrl+s
saves, ctrl+enter saves and connects, tab and shift+tab move between fields.

Profiles are kept in bone's plugin state (`~/.bone/state/gui/ssh.json`).

## The window it opens

The window you typed `/ssh` in stays as it was, and you can close it; the new
window lasts until you close it, and closing it closes the ssh connection. Its
title is the connection's name, and its new chats start in the Start directory
(or the home directory there). Tools, files and shells run on that machine;
`/term` and attached images stay on this one.

- **Linux or macOS host**: the window joins the bone a TUI there uses (an ssh
  tunnel to its socket), so they stay in sync. If none runs, one is started for
  as long as the window is open.
- **Windows host**: bone there uses a named pipe, which ssh cannot forward, so
  the window gets a bone of its own there (`bone --headless` over ssh). It uses
  the same config and sessions but is not live-synced with a bone already
  running there; don't have the same chat open in both.
- **From a Windows desktop**: the window connects to a local named pipe and
  each connection runs ssh; to a Linux or macOS host it joins (or starts) the
  bone there through `python3` on that host.

## Needs

- This machine: Linux with `python3` and `setsid`, or Windows with Python 3 as
  `python` and the OpenSSH client.
- A key-based ssh login (ssh runs with `BatchMode=yes` and never asks for a
  password). Test connection shows the key to add when it is missing.
- The other machine: `bone3` or `bone` on its `PATH`, in `~/.local/bin`, in
  `~/.cargo/bin`, or from npm (`bone-agent`). Windows needs OpenSSH Server, with
  PowerShell as its ssh shell (the default).

The terminal app doesn't need this plugin: run `ssh devbox bone3` instead.
