# Behavior

Tunable knobs for how the model works and communicates. Two mechanisms:

- a **working-style contract** appended to the system prompt, assembled from
  the knobs you enable;
- **mechanical hooks** that enforce what prompts alone cannot: a narration
  nudge after N silent tool calls, and an optional read-before-edit guard.

The narration knob is the headline. Without it, a model can make dozens of
tool calls without a word, and the session looks stuck even while it works.
With it, every N-th silent tool result carries a reminder to say one short
line about what it is doing — the same trick the todo plugin uses for stale
checklists, so it costs nothing until it is needed.

## /behavior

`/behavior` opens the knobs as a native settings page, in the terminal and the
desktop app alike (values persist in `settings.json` and beat `core.lua`).
`/behavior <knob> <value>` sets one directly, with completion:
`/behavior narrate_every 4`, `/behavior verify off`.

## Configuration

```lua
-- ~/.bone/core.lua (all knobs optional; these are the defaults)
bone.config.behavior = {
  narrate_every = 6,           -- nudge after N silent tool calls (0 = off)
  ending = true,               -- never end a turn on a plan or progress note
  verify = true,               -- prove changes before finishing, or say "unverified"
  minimal_diffs = true,        -- change only what the task requires
  no_unrequested_files = true, -- no new tests/docs/helpers unless asked
  final_format = true,         -- final message: outcome first, at most 6 lines
  read_before_edit = false,    -- refuse edit_file on files not read this turn
}
```

`read_before_edit` is off by default because models legitimately read files
through the shell (grep, cat); only `read_file`/`write_file` count as having
seen a file, so strict mode can nag. Turn it on if you want the guarantee.

Benchmarked with bone's self-benchmark rig (bone-abench) on haiku 5.5 and
DeepSeek: the contract rules cost a few hundred prompt tokens and do not
reduce pass rates; the narration nudge removes long silent stretches on
multi-minute tasks.
