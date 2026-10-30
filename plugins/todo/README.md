# Todo

A checklist the model keeps for multi-step work, like Claude Code's
`TodoWrite` or Codex's `update_plan`. The model calls `todo` with the whole
list each time; each item has `text` and a `status` (`pending`,
`in_progress` or `completed`). An optional `title` names the checklist;
send it with every update.

Nothing is stored. The list is the latest *finished, successful* `todo`
call in the chat's own history, so it never appears in another chat and it
survives any number of later tool calls. A call that is still running does
not replace the previous list until it finishes. Sub-agents start empty, and
a fork keeps its parent's list. The terminal and the desktop app both show
that chat's list in a drawer across the bottom, one checklist view drawn by
each: in the terminal a blank row above the title and progress count, in the
desktop app a card with the same title, above the prompt. It
hides when the list is empty or every item is completed. `/todo` shows an
unfinished list again. The drawer is as tall as the list, up to the panel
cap of 10 rows. Pointer clicks do not edit the list.
Completed items have checkmarks in the theme's green (its Success color) and muted,
struck-through text; the active item is bold with an accent-colored arrow. A
colorscheme or config that defines `TodoCheck`, `TodoDone` or `TodoActive`
keeps its own. Native strikethrough
in the terminal requires a Bone build supporting `bone.hl.set(..., { strikethrough = true })`
and a terminal that supports SGR 9. The desktop app draws the same strike.
The tool never makes the model keep working or queues another turn.

While items are open, the `todo` result ends with a one-line nudge to mark
items completed as they finish. If the model then runs 8 other tool calls
without updating the list, the 8th result gets one extra line naming the
open count and the in-progress item, e.g.
`[todo: 3 open, in progress "wire up hook". Mark finished items completed.]`,
and the count starts over. The line is part of that stored tool result, so
the request prefix and prompt cache are untouched, and nothing is added
while the list is fresh or finished. The count lives in memory per session;
after a restart reminders resume with the next `todo` call.

If you interrupt a turn while items are open, your next message reaches the
model with one extra line, e.g.
`[todo: 3 open, in progress "wire up hook". You were interrupted: update the list if the plan changed, or clear it.]`.
It is added only to what the model is sent, never stored, so it does not
appear on screen. Once added it stays on that message in every later
request, so the prompt cache holds; after a restart it drops off and the
cache rebuilds once from that message.

Drawer rendering and visibility do not change model messages or invalidate
the chat render cache. Adding `title` changes the tool schema once on upgrade,
so a provider may need to warm its prompt cache again; subsequent UI-only
updates do not affect it.
