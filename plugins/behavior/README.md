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

Disciplines have levels of impact; style fields shape the voice. Everything
defaults to off (the neutral level): installed, the plugin does nothing until
a knob is raised, from `/behavior` or here:

```lua
-- ~/.bone/core.lua (all knobs optional; these are the defaults)
bone.config.behavior = {
  narrate_every = 0,          -- nudge after N silent tool calls (0 = off)
  ending = "off",             -- off | light | standard | strict
  verify = "off",             -- off | light | standard | strict
  scope = "off",              -- off | light | standard | strict: diffs stay on task
  tone = "plain",             -- plain | friendly | dry | formal
  conciseness = "normal",     -- chatty | normal | concise | terse
  detail = "medium",          -- low | medium | high technical detail
  comments = "normal",        -- none | sparse | normal code comments
  autonomy = "normal",        -- careful | normal | high
  read_before_edit = false,   -- refuse edit_file on files not read this turn
}
```

Each level strengthens the rule: `verify = "light"` asks for cheap proof,
`"standard"` demands the proving command or an explicit "unverified", and
`"strict"` requires naming the command and its result in the final message.
0.2.0 booleans still work (true = standard, false = off; `minimal_diffs` and
`no_unrequested_files` fold into `scope`, `final_format` into `conciseness`).

`read_before_edit` is off by default because models legitimately read files
through the shell (grep, cat); only `read_file`/`write_file` count as having
seen a file, so strict mode can nag. Turn it on if you want the guarantee.

Benchmarked with bone's self-benchmark rig (bone-abench) on haiku 5.5 and
DeepSeek: the contract rules cost a few hundred prompt tokens and do not
reduce pass rates; the narration nudge cut DeepSeek's silent stretches from
22-28 tool calls to 6-10 on multi-minute tasks.
