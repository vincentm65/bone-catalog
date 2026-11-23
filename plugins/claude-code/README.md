# Claude Code

Use your installed Claude Code CLI's Claude.ai subscription login as Bone's model backend. No OAuth tokens are copied or read by the plugin. Bone retains its own transcript, tool execution and approvals; Claude's native tools, MCP servers, skills and configured hooks are disabled.

## Setup

1. Install Claude Code and sign in normally: `claude auth login`.
2. Install this plugin through the Bone catalog, or copy this directory to `~/.bone/plugins/claude-code/`.
3. Reload plugins/restart Bone. In `/config` → Providers choose **claude_code**.

The plugin adds a provider without changing your current selection. Default model: **claude-haiku-5-5**, pinned rather than the moving `haiku` alias to keep model/cache behavior stable. Tested with Claude CLI **2.1.325** and a Claude.ai Pro login. Availability depends on your account and current Anthropic policies.

Optional `~/.bone/core.lua` configuration:

```lua
bone.config.providers.claude_code = {
  type = "claude_code",
  model = "claude-haiku-5-5", -- use an exact model ID for predictable caching
  reasoning_effort = "low",
  timeout_ms = 600000,       -- per model invocation (default 10 min)
  -- Budgets are off by default (subscription usage, list-price estimates).
  -- max_budget_usd = 0.5,     -- CLI allowance per invocation; the CLI SHOWS this to the model
  -- max_turn_budget_usd = 5,  -- Bone-side: stop further invocations once the turn's estimate passes this
  -- continuation_nudge = false, -- see "Turn-ending guard"
  -- executable = "/path/to/claude",
}
-- Select only when you want Claude to handle subsequent turns:
-- bone.config.provider = "claude_code"
```

The CLI's normal HOME / CLAUDE_CONFIG_DIR is retained. API keys, injected OAuth-token variables, API base URLs and alternate-provider flags are removed from the child environment so they cannot silently override the locally stored subscription login. The plugin does not use `--bare` (which disables subscription authentication) or bypass permission checks.

## Images, plan usage and reloads (1.3)

- **Images.** Pasted images and images in tool results reach Claude. New messages go to the CLI as one stream-json user message: the Bone messages as JSON, each image replaced by an `[image N]` label, followed by the images themselves after their labels.
- **`/claude-usage`** shows your plan and each usage window (5-hour, weekly) with what is left and when it resets. Every Claude Code request reports these, so the page shows the latest request's figures and costs nothing to open. When a window's limit stops a request, the error says which one and when it resets.

## Cache and usage

The first invocation sends the current Bone history. Subsequent invocations resume a private CLI session in a stable isolated working directory and send only appended Bone messages. Existing Claude message/cache boundaries remain intact instead of rewriting one growing JSON block. Before every resume, the adapter checks the exact Bone history prefix and system/tool/schema/model settings. History edits, undo, compaction and changed instructions/tools discard the old session and start clean; no prompt-level retractions are used. Every resume runs with `--fork-session`, so a cancelled or failed call never touches the saved session: the next call resumes it with a warm cache instead of resending the whole history (before 1.3.2 a cancel restarted the chat cold). Two failures in a row discard the session, in case it is what fails. No synthetic padding is added in normal use. Cache hits still depend on minimum length, TTL, model, routing, and unchanged prefixes.

Sessions are saved in Bone's state (`~/.bone/state/core/claude-code.json`, which keeps a short digest of each message rather than the transcript), so they survive config reloads (any settings change or plugin save reloads the config) and restarts. Before 1.3 a reload dropped every session, and the next turn of each chat re-sent its whole history as a cold cache write.

A bounded growing-history test measured **98–99% reuse** for short requests after large tool results, and **74–84%** immediately when adding a fresh ~3,600-token result. New tokens necessarily need a cache write; the next request reused them. This is more representative than a repeated-greeting test.

Resumption persists CLI transcripts in the normal Claude config's `projects/` directory for a generated private cwd (`/tmp/bone3-claude-code.*`). Each fork is a full copy of the transcript, so before a call the adapter deletes every transcript in the private project directory except the saved and resumed ones. Those private project directories and working directories are removed when a session resets. When the plugin loads, it forgets sessions idle for six hours and removes any private directory nothing has used for as long, including those left by a Bone that was killed. They are not user project transcripts.

`lua/call` with `{ "name": "claude-code.usage", "session_id": "…" }` returns the latest CLI call's uncached input, cache-read, cache-write, output, incremental list-price estimate, accumulated turn estimate, whether it resumed, the number of appended messages and the continuation nudges. `model_usage` and `cli_session_cost_usd` are CLI-session cumulative; the adapter subtracts prior cumulative cost for budget tracking. Bone's usual `usage.cached_tokens` receives cache-read tokens; total input includes read and write tokens. `usage.context_tokens` is the last real assistant model call's input (including cache reads/writes), not the sum across CLI internal calls. `claude-code.limits` returns `{ plan, info, at }`: the plan from `claude auth status` and the latest request's rate-limit report.

Both budgets are off unless configured. `max_budget_usd` becomes the CLI's `--max-budget-usd`, which the CLI also puts in the model's context (`USD budget: $0/$0.5; $0.5 remaining`); models then ration work or stop early, so only set it when you want a hard cap. `max_turn_budget_usd` is enforced by Bone between invocations and is not shown to the model. Budget figures are CLI list-price estimates, **not a promise about subscription quota or a hard prepaid limit**. A request can cross a budget threshold before the CLI notices; the turn guard stops subsequent invocations. Tool loops consume more than one model invocation. Errors, rate limits and timeouts are not automatically retried by this plugin (other user-installed request-error hooks may retry).

## Turn-ending guard

The system preamble spells out the ending rules: an empty `tool_calls` array ends the
turn, so a reply that announces further work must carry the matching tool calls. If a reply
still arrives with no tool calls but text that reads as unfinished — a plan, "let me know",
a trailing "now." — the adapter resumes the CLI session once and tells the model to continue,
or, if it is done, to reply with nothing more. Since 1.3 the user has already seen the first
reply, so the follow-up is added after it instead of replacing it, and a finished answer costs
only a tiny confirmation rather than a restated reply. Set `continuation_nudge = false` in the
provider entry to disable the extra invocation. In Bone's self-benchmarks the guard removed
every premature turn-end on multi-minute debugging tasks (8/12 to 11/12 passes with haiku on
reverted real bugs).

## Tests

```sh
# Real Bone server, fake CLI: no model tokens consumed
python3 tests/claude_code_test.py
for s in no-budget malformed unknown-tool too-many-tools object-tool-calls timeout turn-budget growth reset; do
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

- Tool calls use Claude structured JSON output, not native Claude tool execution. The CLI receives per-tool argument schemas; the adapter additionally validates tool names, array/object shape and the call-count cap, preserving raw argument JSON (including null and empty collections).
- A reply appears when the CLI call completes, not as Claude writes it.
- Bone's Lua JSON representation can lose null/empty-array distinctions in incoming tool schemas; unusual schemas should be checked before relying on them.
- Requires Linux/Unix `env`, `mktemp` and a compatible Claude CLI. CLI protocol/flags may change.
