# mcp

Loads MCP servers from JSON files, adds local stdio servers, and shows them in
the TUI.

Install with `python3 install.py mcp` from the catalog repository root.

```lua
-- ~/.bone/core.lua
bone.config.mcp_files = { "~/.config/mcp.json" }   -- { "mcpServers": { ... } } files
bone.config.mcp_options = { lazy = true }          -- start each server on first use
```

```text
/mcp-add github github-mcp-server stdio
```

This saves the server in `~/.bone/mcp.json` and reloads the core. The command
accepts a server name, executable, and optional whitespace-separated arguments.

`/mcp` opens a panel with every server, its state, its last error and its
tools (`r` refreshes, `esc` closes). Without the plugin, `bone.mcp.add` and
`bone.mcp.load` in `core.lua` do the same loading; this only saves the call
and adds the panel.
