# usage

A full-screen dashboard of what your sessions used and did, read from the
session index with `store/query`.

```sh
python3 install.py usage
```

`/usage` (or `/stats`) opens the last 7 days; `/usage today`, `week`,
`month`, `year`, `all` or `/usage 2026-09-01..2026-09-30` pick another
period. It shows:

- shared cards with stacked **Current** (conversation lifetime) and **All**
  (selected period) rows for tokens, input, output, cached, requests,
  turns/sessions and tool calls; both keep averages, cache/failure rates,
  and All keeps comparisons with the previous period;
- tokens per hour, day, week or month as a column chart, with the peak and
  average and the current bucket highlighted;
- models with requests, tokens, cache rate and share;
- tools with calls, failure rate and average output;
- a weekday × hour punchcard and a calendar of daily activity with your
  current and longest streak;
- the busiest sessions and where they ran.

Click a period, model, chart bucket, calendar day or session to filter. Active
filter chips remove that filter; **Clear all** resets filters and dates.
`Tab`/`Shift+Tab` and `Enter` access the same actions; `c` clears filters.
`1`-`5` or `←`/`→` (also `d w m y a`) switch period, `t` enters dates,
`j`/`k`, page keys and the wheel scroll, `r` refreshes, `q`/`esc` closes.

Current-chat lifetime cards stay unfiltered. All usage sections follow model
and session filters; tools cannot be attributed to a model and are marked
unfiltered by model. Activity remains all-history within those filters.
Wide terminals get two columns. Scrolling reuses rendered sections; period
switches reuse activity until refresh, a filter change, a new day or reopening.
Mouse filtering requires Bone's popup mouse-hit support; keyboard filtering
works without it.

Usage is recorded per model call from the version that added it on; older
sessions show tool calls but no tokens. It is only TUI Lua: read-only SQL
queries sent with `bone.request("store/query", { sql, params }, callback)` and
a full-screen `bone.ui.popup` drawn with highlight groups (`UsageHeat0`-`4`,
`UsageBar`, `UsageValue`, derived from your colorscheme).
