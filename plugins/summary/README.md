# Summary

Show a concise one-to-three-line summary before every assistant answer. Click
an answer's summary to expand or collapse the full response. The summary is
created with a separate model call after the answer finishes; while it is
being created, a short fallback made from the answer is shown.

- UI: TUI and GUI
- No core half

The plugin is intentionally non-destructive: summaries are display-only and
are not added to the conversation transcript or sent back to the model.
