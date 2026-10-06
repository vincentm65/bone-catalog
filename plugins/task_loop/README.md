# task_loop

A persistent checklist and autonomous loop for each Bone 3 session, with a
32-column sidebar on the right of the chat. Switching sessions switches the
displayed checklist. New sessions, forks and sub-agent sessions start with
their own empty list.

Install through `/catalog`, or from this repository:

```sh
python3 install.py task_loop
```

- `/task fix the parser` adds a task to the current session. Send a first
  message to create the session before adding tasks to a new chat.
- `/tasks` shows or hides the sidebar; its visibility is remembered.
- `/task` focuses the sidebar. `/task_loop` is an alias for `/tasks`, or
  `/task text` when given text.
- In the sidebar: arrows select, Enter/Space toggles done, `s` puts the task
  in the prompt, `d` deletes it, `x` clears completed tasks, Esc returns to
  the prompt.

Adding tasks manually does not start autonomous execution. The model's
`task_loop` tool has these actions:

- `write`, with `tasks` (non-empty strings): replace this session's list and
  start the loop.
- `advance`: finish the first unfinished task.
- `complete`, with a one-based `index`: finish that task.
- `stop`: pause the loop; `resume`: continue if unfinished tasks remain.
- `clear`: remove the list and stop; `status`: show the list.

While active, the checklist is included in this session's model context.
After a completed turn, the loop sends a continuation to the same session.
Completing every task stops the loop; failed or cancelled turns do not send
a continuation. Each action uses the calling session, never a supplied
session ID or a global fallback.

The core and TUI share only that session's file:
`~/.bone/state/shared/task_loop.<sha256-of-session-id>.json`. Different
sessions write different files, so concurrent sessions cannot overwrite
each other's tasks or active flag. Resuming a session restores its list.

Version 1.1.0 leaves the old global `~/.bone/state/shared/task_loop.json`
untouched and does not import it: it has no owning session, so assigning it
automatically would carry tasks across session boundaries. Recreate any
needed tasks in their intended session. Sidebar visibility is saved
separately in TUI plugin state.
