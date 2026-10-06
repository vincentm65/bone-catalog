# Port status

The catalog preserves the old package names while adopting Bone 3's two-sided
Lua runtime.

| Package | Bone 3 entry points | Notes |
| --- | --- | --- |
| `ask_user` | `core.lua`, `tui.lua` | Uses `bone.ask`; questions are asked in the input field (a region in place of the prompt). |
| `cron` | `core.lua` | Requires `BONE3_CRON_COMMAND` when the default headless launcher is not suitable. |
| `goal` | `core.lua`, `tui.lua` | Uses `turn_start`, `turn_end`, `bone.queue`, and persistent state. |
| `history` | `tui.lua` | Alias around the built-in session picker. |
| `mcp` | copied native example | Uses Bone 3's MCP manager rather than the old one-shot client. |
| `recap` | `tui.lua` | Runs a model call outside the session and adds a local chat item. |
| `review` | copied native example | Native changed-file panel; the old verification-first review prompt is a follow-up. |
| `skill` | copied native example | Uses the Bone 3 skill registry and `skill` tool. |
| `subagent` | `core.lua` | Sub-agents run as owned child sessions (`bone.session.create`/`run`); the TUI lists and opens them. |
| `task_loop` | `core.lua`, `tui.lua` | Persistent checklist plus queue-driven continuation. |
| `themes` | `tui.lua`, `colors/*.lua` | Old palette files were converted to Bone 3 highlight groups. |
| `usage` | copied stats example | `/usage` is canonical and `/stats` remains an alias. |
| `web_search` | `core.lua` | Real DuckDuckGo search through `ddgs` when `uv` is installed (as the old package did); otherwise DuckDuckGo's Instant Answer endpoint through `bone.http`, which only knows encyclopedia-style topics. |

The port is intentionally additive: no package is loaded by default. Install a
package, then use `/plugin load <name>` or reload the core/TUI. Package Lua is
trusted code, just like `core.lua` and `tui.lua`.

Compaction is built into Bone 3 (`/compact`, `bone.config.compact`), so the
old `compact` package is gone.
