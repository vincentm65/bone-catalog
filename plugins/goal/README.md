# Goal

Keeps a chat working on an objective, turn after turn, until it is done.
You can leave while it runs.

```
/goal make the parser tests pass --check "cargo test -q"
```

| | |
|---|---|
| `/goal <objective> [--check "cmd"]` | start (a new chat gets a session) |
| `/goal` | its status |
| `/goal stop` | stop; a turn already running finishes (`esc` stops at once) |

To steer a running goal, send a message: it is answered, then the goal
carries on.

## How it works

The first message gives the model the objective and the rules: work
without asking (no `ask_user` or other tools that wait for you), and end
the final reply with `<goal>done</goal>`, or `<goal>blocked: why</goal>`
when only you can unblock it. After each turn the next starts with
`Continue the goal: <objective>` (about 20 tokens plus the objective).

It ends when:

- the model writes `<goal>done</goal>` and the `--check` command passes
  (if it fails, the next turn gets its output);
- the model writes `<goal>blocked: …</goal>`;
- a continuation turn makes no tool calls (no progress);
- you stop it, or a turn fails.

There is no turn limit. A band under the chat shows the running goal:
`◎ make the parser tests pass  turn 7  12m`.

## Isolation

One core hook (`turn_end`), which returns at once for sessions without a
goal. No tools and no system prompt changes, so other sessions are
untouched and the prompt cache is never invalidated: a goal only appends
messages to its own chat. The TUI asks about sessions with a goal only and
overrides nothing.

Running goals are kept in `~/.bone/state/core/goal.json`, which is removed
when the last one ends. A goal survives a reload (`/plugins reload`,
installing a plugin) but not a restart of the core, after which no turn is
left to continue it.
