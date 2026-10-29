# Toolstrip

Toolstrip is the shared tool timeline for the TUI and GUI. Live turns are duration-weighted; historical turns use equal-width segments.
Both frontends use the same timing data, segment categories, running/waiting/
failure states, and navigation behavior. Each frontend renders it in its own
native way: terminal blocks in the TUI and the proportional node bar in the
GUI.

The GUI's standard library (Bone newer than 3.0.3) supplies the full node
renderer: one bar under each open turn, folded rows for earlier turns, hover
descriptions, glowing live segments, and clicks that open a turn and center
the selected tool.

The TUI draws the latest turn's bar above the prompt, running or finished,
with how long the turn took. Once the next message is sent it moves into the
chat: earlier turns fold into one row each, the message and its bar. Click a
folded row to open the turn (on a segment, it opens at that call), and click
an earlier turn's bar anywhere to fold it again; on the latest turn's bar, a
click selects a segment. Opening or folding a turn keeps the view where it is,
even at the end of the chat. As in the GUI, a finished turn ends with its
answer, and the model's time between calls under 300 ms draws no segment.
Each turn's start and finish are saved, so a bar keeps its thinking time
across restarts (turns from before that use the turn footers' saved times
where there are some), and a shell command that exited non-zero stays red.
Clicking a segment of the bar above the prompt selects it, shows its label
(what it did, its exit code or diff size, and how long it took of the turn),
and centers the corresponding chat item. Both sides keep working with old
sessions that do not have persisted tool timings.

Shared options:

- `bone.o.tool_strip` (default `true`) enables the timeline in both frontends.
- `bone.o.fold_turns` (default `true`) folds earlier turns.

TUI settings are available under `/config`:

- `toolstrip.label` (default `true`) shows the selected segment label on the
  bar above the prompt.

The shared highlight groups are `ToolStripModel`, `ToolStripRead`,
`ToolStripCommand`, `ToolStripEdit`, `ToolStripFail`, `ToolStripLive`,
`ToolStripWait`, `ToolStripAnswer`, and `ToolStripAgent`. A colorscheme or
user configuration can override them.
