# Toolstrip

Toolstrip is the shared duration-weighted tool timeline for the TUI and GUI.
Both frontends use the same timing data, segment categories, running/waiting/
failure states, and navigation behavior. Each frontend renders it in its own
native way: terminal blocks in the TUI and the proportional node bar in the
GUI.

The GUI's standard library (Bone newer than 3.0.3) supplies the full node
renderer: one bar under each open turn, folded rows for earlier turns, hover
descriptions, glowing live segments, and clicks that open a turn and center
the selected tool.

The TUI draws a bar under each user message and folds earlier turns into one
row: the message and its bar. Click a folded row to open the turn; on an open
bar, click a segment to select it, and click off the segments (the indent or
the duration) to fold an earlier turn again. Opening or folding a turn keeps
the view where it is, even at the end of the chat. While a turn runs, a live bar
sits above the prompt; clicking a segment there selects it, shows its label,
and centers the corresponding chat item. Both sides keep working with old
sessions that do not have persisted tool timings.

Shared options:

- `bone.o.tool_strip` (default `true`) enables the timeline in both frontends.
- `bone.o.fold_turns` (default `true`) folds earlier turns.

TUI settings are available under `/config`:

- `toolstrip.label` (default `true`) shows the selected segment label on the
  live bar.

The shared highlight groups are `ToolStripModel`, `ToolStripRead`,
`ToolStripCommand`, `ToolStripEdit`, `ToolStripFail`, `ToolStripLive`,
`ToolStripWait`, `ToolStripAnswer`, and `ToolStripAgent`. A colorscheme or
user configuration can override them.
