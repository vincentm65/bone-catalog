# codex

A model provider for OpenAI's Responses API. By default it uses your Codex
CLI login (`~/.codex/auth.json`, or `$CODEX_HOME/auth.json`) and the ChatGPT
Codex backend, so turns count against your ChatGPT plan. Give it an
`api_key` and it uses `https://api.openai.com/v1` instead.

- core half: yes
- TUI half: no

Install with `python3 install.py codex` from the repository root. If you are
logged in to the Codex CLI, a `codex` provider (`gpt-6.1-sol`) appears in
your provider list; pick it in `/config` → Providers. To change it, define
your own in `~/.bone/core.lua` (or edit it in `/config`):

```lua
bone.config.providers.codex = {
  type = "codex",
  model = "gpt-6.1-sol",
  -- reasoning_effort = "medium",  -- low | medium | high | xhigh | max
  -- fast = true,                  -- priority service tier
  -- api_key = os.getenv("OPENAI_API_KEY"),  -- OpenAI API instead of ChatGPT
}
bone.config.provider = "codex"
```

Run `codex login` once first. The token is read on every request, and the
Codex CLI refreshes it in place; if a turn fails with HTTP 401, run `codex`
once to refresh it.

Requests mirror the Codex CLI's routing headers (`session-id`, `thread-id`,
`x-codex-turn-state`) and `prompt_cache_key`, keyed by the bone session, so
a session's turns hit the prompt cache. Reasoning summaries stream as
reasoning. Encrypted reasoning is not carried between calls, because bone's
transcript has nowhere to keep it.

The ChatGPT Codex backend is not a documented API, and it accepts only the
models your plan offers in Codex.
