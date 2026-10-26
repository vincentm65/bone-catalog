# Idle Compact

Compacts the chat you were last using once it has sat idle for a while
with a large context, so your next message starts from a summary instead
of re-sending the whole conversation to a cold cache.

It compacts a chat only when all of these hold:

- your last message went to it (chats you left for another one are never
  compacted, however old they get);
- it is still open in this frontend and no turn is running;
- nothing happened in it for **45 minutes** (your message or a reply);
- its last turn sent at least **50k tokens** of context;
- it has not already been compacted since it was last used.

Both numbers are settings (`/config`, Idle Compact tab):
`idle_compact.minutes` and `idle_compact.threshold`.

Compaction is the core's `session/compact`: the transcript is kept, only
what later model calls send is summarized.

- core half: no
- TUI and GUI: yes
