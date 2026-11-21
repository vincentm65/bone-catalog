# Chat Titler

Names each chat automatically. After a completed turn, a chat that still
carries the core's own title (the first line of its first message) is sent
to the model for a short title, which is set with the same `session/set`
that `/rename` uses.

- A chat you renamed by hand is never touched, also when the rename lands
  while the title is being made.
- A chat whose title call failed is tried again after its next turn, and an
  older chat gets a title the next time you use it.
- One title call per turn, however many TUI and GUI windows are open: the
  core half claims the turn, the window that claimed it sets the title.
- Sub-agent chats are left alone (the subagent tool names them).
- `retitle` looks again after later turns; the model keeps the current title
  unless the conversation's main task has changed.
- The title call uses the chat's own provider and model by default, with a
  `low` reasoning effort when the provider sends one. Set `provider`,
  `model` or `effort` in the settings to change that (a cheap model for
  naming, say).

Settings: `/config` → Plugins → Chat Titler (`auto`, `retitle`, `max_chars`,
`provider`, `model`, `effort`, `debug`).

After installing or updating, run `/plugins reload chat-titler` (or restart
bone) so the core half loads.
