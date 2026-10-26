# Context

See what fills the conversation's context window. It makes no model calls and
runs no external commands. It never edits the transcript and stores no copies of
the conversation.

## Usage

- `/context` shows the **current** context: an estimate that includes the latest
  saved messages.
- `/context request` shows the **last request** this plugin observed, after the
  context hooks ran. `Tab` (or ←/→) switches between the two views; `1` and
  `2` jump to each.
- `r` refreshes. Arrows, `j`/`k`, Page Up/Down, Home/End and the wheel scroll.
  `q` or Escape closes. The open dashboard also refreshes when messages
  complete, turns finish, the conversation compacts or you switch chats.
- In the desktop app, click **Current** or **Last request**, **Refresh** or
  **Close**, and scroll the page. The same keys still work.

The dashboard shows:

- **The total** and a meter split by category: system prompt, compaction
  summary, user and assistant text, reasoning, tool calls, tool results, tool
  schemas and images. When a context window is set, the meter is scaled to it
  and a `┃` marks the proactive compaction threshold; otherwise it is scaled
  to the compaction limit, so the bar shows how close compaction is.
- **Where it stands**: how far it is to compaction, how many messages are active,
  stored and summarized, and the provider's own input and cache count for the
  last call.
- **The breakdown** by category, with item counts and shares.
- **Tool schemas**: every tool offered in the last observed request, including
  unused tools, sorted by estimated token weight. Each shows its schema token
  count and share of all schemas; long names wrap rather than being truncated.
  There is no tool-count limit on this list.
- **Tool costs**: the top 15 combined costs, split into schema, call arguments
  and results, with a bar of each tool's share colored by the part that
  dominates it.
- **The largest messages**, with their share of the total and a one-line
  glimpse (current view only). A message that only calls tools shows what it
  acted on, such as `→ write_file lua/x.lua`.

## Accuracy

Token counts are **estimates**. The plugin divides the observed request's size
by the input count the provider reports for it, which gives this conversation's
bytes per token. This is how Bone calibrates its own compaction estimate, and
"calibrated" in the header shows it has happened. Until then it assumes 4 bytes
per token. Images use Bone's conservative tile allowance. Provider framing and
opaque reasoning are left out. Text reasoning counts as potential replay unless
the provider turns that off.

The current view is a snapshot, not a dry run of the next request, because
later context and request hooks can rewrite it. The system prompt and tool
schema sizes come from this conversation's last observed request. Before the
first request, the plugin estimates the configured static system prompt
without running hooks. Tool schemas are then marked unknown and left out of the
total. Reloading the plugin or restarting Bone clears what it observed, so send
a message to populate it again.

The request view records the latest request hook observation. A hook with an
even lower priority can still change the request after that. The request view
is not the newest transcript and may not be a successful request. The current
view also leaves out pending prompt text, queued messages and unsaved
streaming output.

## Settings

In `/config` → **Context**, set **Context window (tokens)** to scale the meter
and show how full the window is and how much is left. The default is 0, meaning
unknown, because model limits are never guessed. The compaction threshold is
shown separately and is not treated as the model's capacity.

## Install

Install it from `/catalog`. Both `core.lua` and `ui.lua` must load (terminal and desktop). It needs
`bone.session.snapshot`, the request and message hooks, plugin RPC and the Lua
window API.

```sh
luajit tests/context_test.lua   # from the catalog root
```
