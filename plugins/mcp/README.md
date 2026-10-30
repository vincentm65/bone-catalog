# MCP

Loads MCP servers from JSON files and gives you `/mcp`, a popup to see and
manage them.

Install with `python3 install.py mcp` from the catalog repository root.

```lua
-- ~/.bone/core.lua
bone.config.mcp_files = { "~/.config/mcp.json" }   -- { "mcpServers": { ... } } files
bone.config.mcp_options = { lazy = true }          -- start each server on first use
```

## /mcp

Servers on the left, the selected one on the right: its state, endpoint or
command, last error, and every tool with its description.

| Key | Does |
| --- | --- |
| `a` | add a server: a name, then a command line or an `https://` URL (and an optional `Authorization` value) |
| `r` | reconnect now (also revives a server that gave up) |
| `s` / enter | sign in to an HTTP server (OAuth) |
| `c` | while signing in: copy the sign-in address (tmux, OSC 52 over SSH, or wl-copy/xclip) |
| `x` | sign out |
| space | enable or disable (servers added here, in `~/.bone/mcp.json`) |
| `d` | remove (same) |
| up / down | choose a server |
| pgup / pgdn | scroll |

`/mcp-add NAME COMMAND [ARGS...]` (or `NAME URL`) does the same as `a`.

The terminal and the desktop app draw the same view. Click a server to select
it; **Add**, **Reconnect**, **Sign in**, **Sign out**, **Enable** / **Disable**,
**Remove** and **Copy address** run the same actions as the keys.

## Signing in

An HTTP server that answers 401 shows as **sign in needed**. Press `s`: bone
registers itself with the server, opens the browser (when it can) and waits for
the redirect. When the browser is on another machine, for example over SSH, the
redirect lands there and fails to load; paste the address it ended up on into
the popup. Press `c` to copy the address when the browser does not open. Tokens are kept in `~/.bone/mcp-auth.json` and refreshed on their
own; when a refresh fails the server goes back to "sign in needed". A server
configured with its own `Authorization` header never uses OAuth. For servers
that refuse registration, set `client_id` in its config.
