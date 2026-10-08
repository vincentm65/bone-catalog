# Claude Code provider

Use your installed Claude Code CLI's Claude.ai subscription login as Bone's model backend. No OAuth tokens are copied or read by the plugin. Bone retains its own transcript, tool execution and approvals; Claude's native tools, MCP servers, skills and configured hooks are disabled.

## Setup

1. Install Claude Code and sign in normally: `claude auth login`.
2. Install this plugin through the Bone catalog, or copy this directory to `~/.bone/plugins/claude-code/`.
3. Reload plugins/restart Bone. In `/config` → Providers choose **claude_code**.

The plugin adds a provider without changing your current selection. Default model: **claude-haiku-5-5**, pinned rather than the moving `haiku` alias to keep model/cache behavior stable. Tested with Claude CLI **2.1.293** and a Claude.ai Pro login. Availability depends on your account and current Anthropic policies.

Optional `~/.bone/core.lua` configuration:

```lua
bone.config.providers.claude_code = {
  type = "claude_code",
  model = "claude-haiku-5-5", -- use an exact model ID for predictable caching
  reasoning_effort = "low",
  timeout_ms = 120000,
  max_budget_usd = 0.5,      -- CLI allowance per model invocation
  max_turn_budget_usd = 1,  -- stop further invocations after accumulated turn usage
  -- executable = "/path/to/claude",
}
-- Select only when you want Claude to handle subsequent turns:
-- bone.config.provider = "claude_code"
```

The CLI's normal HOME / CLAUDE_CONFIG_DIR is retained. API keys, injected OAuth-token variables, API base URLs and alternate-provider flags are removed from the child environment so they cannot silently override the locally stored subscription login. The plugin does not use `--bare` (which disables subscription authentication) or bypass permission checks.

## Cache and usage

The first invocation sends the current Bone history. Subsequent invocations resume a private CLI session in a stable isolated working directory and send only appended Bone messages. Existing Claude message/cache boundaries remain intact instead of rewriting one growing JSON block. Before every resume, the adapter checks the exact Bone history prefix and system/tool/schema/model settings. History edits, undo, compaction, changed instructions/tools, failures, and cancellation discard the old session and start clean; no prompt-level retractions are used. No synthetic padding is added in normal use. Cache hits still depend on minimum length, TTL, model, routing, and unchanged prefixes.

A bounded growing-history test measured **98–99% reuse** for short requests after large tool results, and **74–84%** immediately when adding a fresh ~3,600-token result. New tokens necessarily need a cache write; the next request reused them. This is more representative than a repeated-greeting test.

Resumption temporarily persists CLI transcripts in the normal Claude config's `projects/` directory for a generated private cwd. Those private project directories and working directories are removed on reset/failure/config shutdown. A process crash can leave them behind; they are not user project transcripts.

`lua/call` with `{ "name": "claude-code.usage", "session_id": "…" }` returns the latest CLI call's uncached input, cache-read, cache-write, output, incremental list-price estimate, accumulated turn estimate, whether it resumed, and the number of appended messages. `model_usage` and `cli_session_cost_usd` are CLI-session cumulative; the adapter subtracts prior cumulative cost for budget tracking. Bone's usual `usage.cached_tokens` receives cache-read tokens; total input includes read and write tokens.

Budget figures are CLI list-price estimates, **not a promise about subscription quota or a hard prepaid limit**. A request can cross a budget threshold before the CLI notices; the turn guard stops subsequent invocations. Tool loops consume more than one model invocation. Errors, rate limits and timeouts are not automatically retried by this plugin (other user-installed request-error hooks may retry).

## Tests

```sh
# Real Bone server, fake CLI: no model tokens consumed
python3 tests/claude_code_test.py
for s in malformed unknown-tool too-many-tools object-tool-calls timeout turn-budget growth reset; do
  python3 tests/claude_code_test.py --scenario "$s"
done

# Explicit opt-in: new isolated Bone thread, three tiny Haiku turns;
# modest fixed prefix for cache threshold + harmless tool roundtrip.
python3 tests/claude_code_test.py --live
# Growing transcript: three large synthetic tool results, six bounded model calls
python3 tests/claude_code_test.py --live --scenario growth
```

Set `BONE_BIN` if the Bone binary is not at `../bone3/target/debug/bone` relative to this catalog. Tests isolate Bone config/data and do not change your default provider or credentials.

## Limitations

- Text-only; images are rejected rather than silently omitted.
- Replies appear at completion, not live token-by-token.
- Tool calls use Claude structured JSON output, not native Claude tool execution. The CLI receives per-tool argument schemas; the adapter additionally validates tool names, array/object shape and the call-count cap, preserving raw argument JSON (including null and empty collections).
- Bone's Lua JSON representation can lose null/empty-array distinctions in incoming tool schemas; unusual schemas should be checked before relying on them.
- Requires Linux/Unix `env`, `mktemp` and a compatible Claude CLI. CLI protocol/flags may change.
