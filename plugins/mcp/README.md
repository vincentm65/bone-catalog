# MCP

Loads MCP servers from JSON files, loads their tools on demand, and gives you
`/mcp`, a popup to see and manage the servers and their tools.

Install with `python3 install.py mcp` from the catalog repository root.

```lua
-- ~/.bone/core.lua
bone.config.mcp_files = { "~/.config/mcp.json" }   -- { "mcpServers": { ... } } files
bone.config.mcp_options = { lazy = true }          -- start each server on first use
```

An entry of such a file may carry its own `"tools": { "allow": [...], "deny": [...] }`,
`"lazy"` and `"timeout"` (ms per call). An entry that cannot be loaded (a
name outside letters, digits, `_` and `-`, say) is skipped and shown in
`/health`; the rest of the file still loads.

A lazy server starts with the first message. On a bone with
`bone.mcp.start` it starts when one of its tools is first called instead,
once its tools are remembered from an earlier run and all of them load on
demand (none pinned, loading not `off`); `/mcp` shows it as idle until then.

## Tools on demand

Every tool definition of every server rides along with each request, and a
few servers add up to thousands of tokens. Past 2000 tokens of definitions
the model gets two tools in their place:

- `mcp_search` names every server's tools in its description, and answers a
  query (words, or tool names) with descriptions and argument schemas;
- `mcp_call` runs one: `{ server, tool, arguments }`.

What the model is sent then stays the same while servers start, stop and
restart, so a provider's prompt cache (or a local model's) survives them. The
tool names are remembered between runs, in `~/.bone/state/core/mcp-tools.json`.

`mcp_call` checks the arguments against the tool's schema (what is required,
what is unknown, the plain types) and answers a wrong call with what is wrong
and, the first time, the schema; so a model that guessed gets it right on the
next try. An empty list among the arguments is sent as given (a bone before
`bone.mcp.start` cannot tell it from an empty object, and leaves an optional
one out).

Settings, in `/config` under MCP:

| Setting | Does |
| --- | --- |
| Load tools on demand | `auto` (past the size below), `on`, or `off` (every definition, as before) |
| On demand above (tokens) | the size `auto` waits for; 2000 |
| Longest tool result (bytes) | a longer result reaches the model as its start and end, with all of it in a file under the temporary directory it can read; 40000, 0 for no limit |

Each tool is on, pinned or off (set in `/mcp`, kept in
`~/.bone/state/core/mcp-policy.json`):

- **on**: loaded on demand when that is in effect, else with every request;
- **pinned**: always loaded with its own definition, and called by its own
  name (`server_tool`). For the few tools used all the time, and for a tool
  another plugin names (a sub-agent's `tools`, an approval rule);
- **off**: not offered to the model, and refused if it asks anyway.

Other plugins' `tool_call` hooks see `mcp_call` with `{ server, tool,
arguments }` for a tool loaded on demand, and the tool's own name (with
`ev.mcp`) for a pinned one. Calls through `mcp_call` run one at a time; a
pinned read-only tool runs alongside others as before.

## /mcp

Servers on the left, the selected one on the right: its state, endpoint or
command, last error and its first tools. Under them, how tools are loaded and
how many tokens of definitions each request carries.

| Key | Does |
| --- | --- |
| enter / `t` | the server's tools (enter signs in instead while a sign-in is needed) |
| `a` | add a server: a name, then a command line (and its environment, `KEY=value KEY2=value`) or an `https://` URL (and an optional `Authorization` value) |
| `r` | reconnect now (also revives a server that gave up) |
| `s` | sign in to an HTTP server (OAuth) |
| `c` | while signing in: copy the sign-in address (tmux, OSC 52 over SSH, or wl-copy/xclip) |
| `x` | sign out |
| space | enable or disable (servers added here, in `~/.bone/mcp.json`) |
| `d` | remove (same) |
| `l` | how tools are loaded: auto, on, off |
| up / down | choose a server |
| pgup / pgdn | scroll |

In a server's tools: each tool with its description, its arguments and the
size of its definition.

| Key | Does |
| --- | --- |
| space | turn the tool off or on |
| `p` | pin or unpin it |
| `/` | filter by name or description (enter keeps the filter, esc clears it) |
| up / down | choose a tool |
| esc | back to the servers |

`/mcp-add NAME COMMAND [ARGS...]` (or `NAME URL`) does the same as `a`.

The terminal and the desktop app draw the same view. Click a server or a tool
to select it; the buttons run the same actions as the keys.

Outside the popup, a message says when a server needs a sign-in, fails or is
back, and the new-chat screen keeps a line while one needs attention. In the
chat a call reads `server › tool arguments`.

## Signing in

An HTTP server that answers 401 shows as **sign in needed**. Press `s`: bone
registers itself with the server, opens the browser (when it can) and waits for
the redirect. When the browser is on another machine, for example over SSH, the
redirect lands there and fails to load; paste the address it ended up on into
the popup. Press `c` to copy the address when the browser does not open. Tokens are kept in `~/.bone/mcp-auth.json` and refreshed on their
own; when a refresh fails the server goes back to "sign in needed". A server
configured with its own `Authorization` header never uses OAuth. For servers
that refuse registration, set `client_id` in its config.
