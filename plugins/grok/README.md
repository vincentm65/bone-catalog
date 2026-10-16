# Grok

A model provider for xAI's Grok over the Responses API. By default it uses
your Grok Build CLI login (`~/.grok/auth.json`, or `$GROK_HOME/auth.json`,
or `$GROK_AUTH_PATH`) and the endpoint Grok Build itself talks to, so turns
count against your Grok plan (SuperGrok / X subscription) instead of being
billed per token. Give it an `api_key` and it uses `https://api.x.ai/v1`.

- core half: yes
- TUI half: no

Install with `python3 install.py grok` from the repository root. If you are
logged in to Grok Build, a `grok` provider (`grok-4.7`) appears in your
provider list; pick it in `/config` → Providers. To change it, define your
own in `~/.bone/core.lua` (or edit it in `/config`):

```lua
bone.config.providers.grok = {
  type = "grok",
  model = "grok-4.7",
  -- reasoning_effort = "medium",
  -- api_key = os.getenv("XAI_API_KEY"),  -- xAI API instead of your plan
}
bone.config.provider = "grok"
```

Install Grok Build (`curl -fsSL https://x.ai/cli/install.sh | bash`) and run
`grok login` once first. The token is read on every request. Tokens last about
six hours and only the Grok CLI renews them, so when one has less than five
minutes left the plugin runs `grok models` (about half a second), which
renews it in place; the plugin never writes the login itself. If renewing
fails, sign in again with `grok login`. `GROK_CLI_CHAT_PROXY_BASE_URL` and the provider's `base_url`
override the endpoint, as they do for Grok Build.

The plugin only decides where requests go and how they sign in; bone's
built-in Responses provider (`api = "responses"`) builds and sends them, so
it needs a bone with Lua `prepare` providers. Every request carries
the same `x-grok-conv-id` (set `cache_key` on the provider to change it), so
xAI routes them to a server that already holds the cached system prompt and
tools, and even a new session's first call hits the prompt cache.

The Grok Build endpoint is not a documented API: xAI can change it, its
headers or its models at any time, and it accepts only the models your plan
offers in Grok Build (`grok models` lists them).
