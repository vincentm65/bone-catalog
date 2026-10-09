# mcp

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
| `x` | sign out |
| space | enable or disable (servers added here, in `~/.bone/mcp.json`) |
| `d` | remove (same) |
| pgup / pgdn | scroll the tools |

`/mcp-add NAME COMMAND [ARGS...]` (or `NAME URL`) does the same as `a`.

## Signing in

An HTTP server that answers 401 shows as **sign in needed**. Press `s`: bone
registers itself with the server, opens the browser (when it can) and waits for
the redirect. When the browser is on another machine, for example over SSH, the
redirect lands there and fails to load; paste the address it ended up on into
the popup. Tokens are kept in `~/.bone/mcp-auth.json` and refreshed on their
own; when a refresh fails the server goes back to "sign in needed". A server
configured with its own `Authorization` header never uses OAuth. For servers
that refuse registration, set `client_id` in its config.
