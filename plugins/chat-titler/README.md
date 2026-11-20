# Chat Titler

Names each chat automatically. After the first completed turn, the first
user message (plus the opening reply) goes to the model for a short title,
which is set with the same rename the `/rename` command uses.

- A chat you renamed by hand is never touched.
- Retries are debounced: the title lands a couple of seconds after the
  turn ends, and never on a chat that has moved on.
- `retitle` in the settings re-generates the title after later turns too.
- The title call uses the chat's own provider and model by default. Set
  `provider` and/or `model` in the settings to use another one (a cheap
  model for naming, say).

Settings: `/config` → Chat Titler (`auto`, `retitle`, `max_chars`,
`provider`, `model`).
