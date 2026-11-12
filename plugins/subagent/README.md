# Subagents

Delegate tasks to sub-agents that run in sessions of their own.

The `subagent` tool starts a session owned by the calling tool call, runs the
task there with the same tools, and returns the sub-agent's final answer.
Several calls in one reply run at the same time; sub-agents may start
sub-agents two levels deep by default. Bone's TUI lists running sub-agents under the
prompt; click one (or select it and press enter) to open its transcript.

## Following up, messaging and background work

Every answer ends with the agent's handle, e.g. `[agent 1a2b3c4d]`.

- **Follow up:** pass the handle as `session` to give an idle agent another
  task. It keeps everything it learned the first time.
- **Message:** if that agent is still working, the message is slipped into its
  current turn and the call returns at once. Agents working for the same
  top-level session can message each other the same way, and their main chat
  (it gets the message mid-turn, or starts a turn for it). An agent too deep
  to start new agents can still message.
- **List:** `list = true` shows who the caller can message, with handles and
  busy/idle: the agents on its task, plus its main chat for an agent. It is
  asked for, not put in the tool description, so the provider's prompt cache
  is not broken each time an agent starts.
- **Other chats:** with **Message other chats** on (`subagent.cross_session`,
  off by default), a chat's agent can also list and message your other chats
  on the same core. The list shows busy chats and idle ones with a turn in the
  last 30 minutes, at most 10 (both settings); older chats are counted and
  still reachable by handle. Sub-agents never reach other chats.
- **Background:** `background = true` returns at once; the answer arrives in
  the calling session as a message when the agent is done.
- **Failures** return what the agent wrote before it stopped, plus its handle,
  so it can be resumed.

## Choosing the provider and model

The model may pass `provider` and `model` when you ask for them ("use the fast
provider for this"); the tool lists your configured providers. The call wins
over the named agent's settings, which win over the defaults below. A provider
that isn't configured, or one that fails while the agent runs, falls back to
those defaults, and the answer says so. The choice is kept for the run only:
after a core restart the agent returns to its defaults.

## Defaults

Configure defaults in `/config` → **Subagents**. Settings are saved under
`subagent.*` and are read live:

| Setting | Default | Behavior |
| --- | --- | --- |
| Maximum nesting depth | 2 | 0 disables delegation; 1 direct children only; 2 permits grandchildren. |
| Allow nested delegation | on | Turning off clamps depth to 1; it never overrides depth 0. |
| Maximum concurrent subagents | 8 | Global across sessions, including nested children. 0 means unlimited. Extra calls from the main agent wait for a free slot; extra nested calls fail immediately, since waiting there could deadlock. |
| Default provider | blank | Configured provider entry name; blank uses the child session's provider. |
| Default model | blank | Model ID supported by that provider; blank uses its configured model. |
| Default instructions | blank | Prepended to the normal system prompt; blank uses the built-in subagent role. |
| Message other chats | off | A chat's agent can list and message your other running chats. |
| Recent chats window | 30 | Minutes: idle chats older than this are left out of the list. |
| List size | 10 | At most this many agents, and chats, in a list. |
| Allowed tools | blank | Comma-separated names; blank or `*` allows all, `none` or `[]` allows none. Include `subagent` to allow nested delegation. |

Defaults only affect child sessions, not the main agent. Tool restrictions are
both hidden from the model and enforced on tool calls. The concurrency cap does
not change Bone's separate limit of eight parallel tool calls per model reply.
Lowering the cap does not cancel existing children, but blocks new launches.
Cancelled children retain their slots until their turns finish.

## Custom agents

**`/subagents`** opens a popup: agents on the left, the selected one's settings
on the right. Every change is saved at once.

- `n` creates an agent (a name, then its fields); `r` renames, `d` deletes.
- Up/down move through the agents and then the selected one's fields:
  description (advertised to the model), system prompt, provider, model and
  allowed tools. Enter (or a click) edits a field; `x` clears it so it inherits
  the default.
- The system prompt takes multiple lines (enter adds one, ctrl+s saves).
- Provider is picked from your configured providers.
- Tools: comma-separated names, `*` for all, `none` for no tools.
- `/subagents name` opens an agent, or starts creating it.

Agents are stored as an object in `subagent.agents`. Saved agents override Lua
agents with the same name. Changes are advertised on the next model request and
used for future launches; each running child retains its named-agent spec.
Global defaults remain live. The editor manages saved agents only, not Lua entries.

Optional named agents still work in `~/.bone/core.lua`:

```lua
bone.config.subagents.reviewer = {
  description = "reviews a diff for bugs", -- shown to the model
  system = "You review code ...",          -- put before the system prompt
  provider = "fast",                       -- a bone.config.providers entry
  model = "model-id",                     -- optional model override
  tools = { "read_file", "shell" },        -- allowed tools (default: all)
}
```

- core half: yes
- UI: yes, one view for the terminal and the desktop app (`/subagents` editor; click an agent or a field, or New / Rename / Delete; owned sessions shown by Bone itself)
- Chat (`tui.lua`, `gui.lua`): a background agent's row shows as running, with
  its own clock, until the agent finishes; the plugin's own messages (an
  agent's report, a message between agents or chats) are drawn as a short
  report you can click open, not as something you typed.
- needs a Bone 3 core with `bone.session.create` / `bone.session.run`
- Per-agent/default model overrides and reliable cancellation cleanup require
  a core with request-hook `model` support and cancellation-safe `turn_end` hooks.
- A child's role, whitelist and depth survive a core restart on a core with
  `bone.session.info` (the owner is read back from the session header).

Install with `python3 install.py subagent` from the repository root.
