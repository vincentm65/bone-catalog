# subagent

Delegate tasks to sub-agents that run in sessions of their own.

The `subagent` tool starts a session owned by the calling tool call, runs the
task there with the same tools, and returns the sub-agent's final answer.
Several calls in one reply run at the same time; sub-agents may start
sub-agents two levels deep. Bone's TUI lists running sub-agents under the
prompt; click one (or select it and press enter) to open its transcript.

Named sub-agents, in `~/.bone/core.lua`:

```lua
bone.config.subagents.reviewer = {
  description = "reviews a diff for bugs", -- shown to the model
  system = "You review code ...",          -- put before the system prompt
  provider = "fast",                       -- a bone.config.providers entry
  tools = { "read_file", "shell" },        -- allowed tools (default: all)
}
```

- core half: yes
- TUI half: no (the TUI shows owned sessions on its own)
- needs a Bone 3 core with `bone.session.create` / `bone.session.run`

Install with `python3 install.py subagent` from the repository root.
