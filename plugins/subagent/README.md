# subagent

Delegate tasks to sub-agents that run in sessions of their own.

The `subagent` tool starts a session owned by the calling tool call, runs the
task there with the same tools, and returns the sub-agent's final answer.
Several calls in one reply run at the same time; sub-agents may start
sub-agents two levels deep by default. Bone's TUI lists running sub-agents under the
prompt; click one (or select it and press enter) to open its transcript.

## Defaults

Configure defaults in `/config` → **Subagents**. Settings are saved under
`subagent.*` and are read live:

| Setting | Default | Behavior |
| --- | --- | --- |
| Maximum nesting depth | 2 | 0 disables delegation; 1 direct children only; 2 permits grandchildren. |
| Allow nested delegation | on | Turning off clamps depth to 1; it never overrides depth 0. |
| Maximum concurrent subagents | 8 | Global across sessions, including nested children. 0 means unlimited. Extra calls fail immediately, rather than queueing and risking nested-delegation deadlock. |
| Default provider | blank | Configured provider entry name; blank uses the child session's provider. |
| Default model | blank | Model ID supported by that provider; blank uses its configured model. |
| Default instructions | blank | Prepended to the normal system prompt; blank uses the built-in subagent role. |
| Allowed tools | blank | Comma-separated names; blank or `*` allows all, `none` or `[]` allows none. Include `subagent` to allow nested delegation. |

Defaults only affect child sessions, not the main agent. Tool restrictions are
both hidden from the model and enforced on tool calls. The concurrency cap does
not change Bone's separate limit of eight parallel tool calls per model reply.
Lowering the cap does not cancel existing children, but blocks new launches.
Cancelled children retain their slots until their turns finish.

## Custom agents

Use **`/subagents`** to add, edit, rename, and delete agents without writing Lua.
Each has a name, description (advertised to the model), system prompt, provider,
model, and allowed tools. `/subagents add reviewer` creates an agent;
`/subagents reviewer` opens its editor.

- Enter edits a field; arrows/Tab choose fields; **s** or **Ctrl+S** saves.
- **d** deletes with confirmation; Esc backs out, confirming unsaved changes.
- System prompts accept multiline paste, or typed `\n` escapes for newlines.
- Blank optional fields inherit defaults. Tools `*` explicitly allows all even
  with restricted defaults; `none` or `[]` explicitly allows no tools.
- Provider means a configured entry name, not an API type; model is an optional
  model ID for that entry. Blank provider/model fields inherit independently.

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
- TUI half: yes (`/subagents` editor; owned sessions shown by Bone itself)
- needs a Bone 3 core with `bone.session.create` / `bone.session.run`
- Per-agent/default model overrides and reliable cancellation cleanup require
  a core with request-hook `model` support and cancellation-safe `turn_end` hooks.

Install with `python3 install.py subagent` from the repository root.
